# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

A teaching repo (article + video + code): deploy a small LLM on Kubernetes. The docs **assume the reader starts from scratch**: `infra/` builds a disposable Linode K3s lab with an on-demand GPU worker and is the default way in. Readers who already have a cluster can skip it and deploy `manifests/` there (`KUBE_CONTEXT` mode). Baseline is Kubernetes 1.36 via K3s. The GPU path passed all 11 checks on one real session (2026-10-28), and teardown (`down` + `verify`) passed on that session, but an unattended `up` and a real reaper deletion have **not** run for real yet; keep docs honest about that (`docs/tested-environments.md` is the record of what has actually run).

## Commands

No unit-test suite. Validation is lint + render + the scripts that exercise a live cluster.

```bash
# lint (install shellcheck, yamllint, black, ansible-lint into a throwaway venv; none are global)
shellcheck -x scripts/*.sh manifests/base/entrypoint.sh
yamllint manifests infra                    # .yamllint ignores generated inventory/Pulumi.*.yaml
black --check infra/pulumi/base/__main__.py infra/pulumi/gpu/__main__.py
(cd infra/ansible && ansible-lint)          # ansible-playbook <pb> --syntax-check for one playbook

# manifests
kubectl kustomize manifests/overlays/cpu    # also: gpu
KUBE_CONTEXT=<ctx> ./scripts/check-prerequisites.sh
KUBE_CONTEXT=<ctx> kubectl --context <ctx> apply -k manifests/overlays/cpu
KUBE_CONTEXT=<ctx> ./scripts/smoke-test.sh  # the closest thing to a test; rollout + /api/tags + bounded inference

# Pulumi (two projects; ALWAYS pass --stack, never rely on the selected stack)
./scripts/check-linode-token.sh              # pre-flight: token set, valid, can create instance/VPC/firewall (creates nothing)
pulumi preview --stack lab                  # in infra/pulumi/base; passes even with NO token, so it proves nothing about auth
./scripts/gpu-session.sh plan --plan g2-gpu-rtx4000a1-s --hours 1   # read-only cost estimate
```

Local kind test cluster: scripts accept `LAB_KUBECONFIG=<file>` to target a kubeconfig other than `.lab/kubeconfig`.

## Safety rules specific to this repo

- `pulumi up/destroy`, `gpu-session.sh up/down`, `gpu-reaper.sh --execute`, `playbooks/reaper.yml`, and any `kubectl delete` are billable or destructive. Run them only after explicit approval in the current message. `up` and `down` require a human typing the session id on a tty, by design; there is no bypass.
- The Linode account may also hold **unrelated resources** (the operator accepted this risk). Never act by tag sweep or name pattern; act only on explicit instance IDs and stacks this repo created.
- Tokens come from the operator's macOS Keychain (one Pulumi token, one separate reaper token; ask which service names). Read them inside a single command with `security find-generic-password -s <name> -w`; never print or store them. Each Bash call is a fresh shell, so `export` does not persist between calls.
- Never put real IPs, instance/stack ids, or account details in tracked files.

## Git

Commit directly to `main` in this repo (no feature branches). Conventional commits (`type(scope): summary`), no AI attribution trailer. Committing and pushing still require explicit approval in the current message, after showing the staged files and proposed message.

## Architecture (needs several files to understand)

**Target selection** (`scripts/lib.sh`): every script resolves its cluster explicitly, either `KUBE_CONTEXT=<name>` (existing-cluster mode) or the lab kubeconfig `.lab/kubeconfig` (written by the Ansible bootstrap). It refuses to fall back to the current kubectl context. `lib.sh` also holds the Linode API helpers (token passed to curl on stdin, never argv).

**Manifests** (`manifests/`): `base` is hardware-agnostic (Ollama server, PVC, Service, NetworkPolicy, SA; `entrypoint.sh` starts the server and pulls the model only if missing; readiness is gated on the model being present). Overlays differ only in resources, model (`MODEL_NAME` via a merged ConfigMap) and, for `gpu`, `runtimeClassName: nvidia`, the `nvidia.com/gpu.present` node selector and an own namespace `llm-inference-gpu` so it can coexist with the CPU demo (`llm-inference`). `manifests/validation/cross-node-job.yaml` is a template filled by `validate-gpu.sh`.

**Two Pulumi projects, deliberately separate** (`infra/pulumi/`):
- `base` (persistent): VPC + subnet, the K3s server (public + VPC interfaces, fixed VPC IP), and the base firewall. Contains no GPU resource. The firewall admits node-to-node ports by **VPC subnet CIDR**, so a node added later needs no firewall change.
- `gpu` (ephemeral, one stack per session named `gpu-<id>`): the GPU instance and its own session firewall. It reads base outputs through a read-only `StackReference` and must never own or modify base resources. A Linode can have only one firewall, which is why the session firewall is separate.

**GPU session lifecycle** (`scripts/gpu-session.sh`): `plan` (cost) → `up` (typed approval → `pulumi up` → Ansible `gpu-session.yml` → deploy GPU overlay → `validate-gpu.sh`; reports ACTIVE only if all checks pass; on failure it prints created resources and the `down` command and never auto-destroys) → `down` (delete namespace first so the volume is cleaned, destroy the stack, delete the stale Node, remove the stack, then `verify`). `verify` proves the instance returns 404, the session tag lists no billable objects, and the base server still exists. Session records live in `.lab/sessions/<id>/`. `up` refuses unless the reaper timer is active on the server.

**Expiry enforcement is independent of the tooling**: tags (`llm-exp-<epoch>`) delete nothing. `scripts/gpu-reaper.sh` (curl+jq only) is installed on the control-plane server as a systemd timer by the `gpu_reaper` role. It deletes an instance only if it has the `llm-gpu-session` and `llm-inference-lab` tags, an `llm-gpu-` label, no `k3s-server` tag, and an expired tag. It defaults to dry-run.

**Ansible** (`infra/ansible/`): `bootstrap.yml` is server-only. `gpu-session.yml` runs: gpu_addons on the server (NVIDIA device plugin and dcgm-exporter as K3s `HelmChart` manifests) → common + `gpu_runtime` (driver, container toolkit, reboot) on the GPU node → `k3s_agent`. GPU runtime must precede the agent because K3s detects the NVIDIA runtime at start. The agent reads the join token from the server at run time. `k3s_version` lives only in `group_vars/all.yml`, is shared by both nodes, and is guarded by a regex that rejects channels and non-1.36 versions.

## Traps already hit

- **flannel must be pinned to the VPC interface** (`flannel-iface`, derived from the host's own VPC address). K3s otherwise binds VXLAN to the public `eth0` even when `node-ip` is the VPC IP, and the firewall then drops pod traffic. A single node cannot reveal this.
- VM hostnames boot as `localhost`; the `common` role sets `lab_hostname` (`llm-lab-server` / `llm-<inventory name>`, from group_vars) before K3s installs, and K3s `node-name` uses the same variable. Do not change it on a running cluster (it renames the node).
- `pulumi-linode` 6.x: `Instance.ip_address` is deprecated with no replacement output (warning only). `interface_generation="legacy_config"` is set because the account default may be the newer interfaces generation.
- Scripts must run under macOS bash 3.2: an empty array expanded under `set -u` fails (`${arr[@]+"${arr[@]}"}`), and `set -e` is ignored inside functions called from `||`, which is why `gpu-session.sh` uses an ERR trap. The Bash tool's default shell is zsh (no word splitting of unquoted variables).
- Ansible in this tool environment needs output piped (`| cat`) to avoid a blocking-IO error; set `ANSIBLE_PYTHON_INTERPRETER=/usr/bin/python3.12` for the lab host.
- **Linode reuses public IPs**, so `.lab/known_hosts` pins go stale on every rebuild (`REMOTE HOST IDENTIFICATION HAS CHANGED`; seen twice). `generate-inventory.sh` tracks the instance id per address in `.lab/known_host_instances` and forgets a pin only when the id changes. Never disable host-key checking to work around it.
- This repo's path contains a space and an emoji; always quote paths. The generated inventory passes the known_hosts path via a JSON-quoted `ansible_ssh_common_args`.
- The `kubectl` on the operator's machine is 1.34; against the 1.36 server it works but warns about version skew (`check-prerequisites.sh` warns too).
- Not validated for real yet: an unattended `up` from start to finish (the first real run needed two fixes and a manual resume), and a real reaper deletion on Linode. Stub-based tests replace the real playbook run, which is how two real bugs (group_vars not found for a session inventory outside `infra/ansible`; the K3s agent installer needing `K3S_TOKEN_FILE`) slipped through.
