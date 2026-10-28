# Tested environments

Only environments listed here have been verified. One live environment (kind) has been tested; see Results.

## Results

| Environment | Kubernetes version | Path (CPU/GPU) | Nodes / resources | Storage class | Date tested | Result | Notes |
|---|---|---|---|---|---|---|---|
| kind v0.30.0 on Docker Desktop 29.6.1 (arm64 host, VM 12 CPU / 8 GB) | v1.34.0 (`kindest/node:v1.34.0`) | CPU | 1 control-plane node | `standard` (rancher.io/local-path) | 2026-10-07 | pass | Fresh cluster `llm-lab`. Restart reused the cache (Ready in 7s, no model re-download). NetworkPolicy enforced: pod in `default` blocked, same-namespace pod allowed. amd64 not tested. |
| Linode `us-ord`: 2-node K3s lab (`g6-standard-4` server + `g2-gpu-rtx4000a1-s` GPU worker, VPC) | v1.36.5+k3s1 on both nodes | GPU | server + 1x RTX 4000 Ada (20 GB), Ubuntu 24.04, kernel 6.8.0-134 | local-path | 2026-10-28 | pass with changes | All 11 GPU checks passed. Driver `nvidia-headless-580-server` 580.178.04, toolkit 1.20.1-1, device plugin chart 0.20.1, dcgm-exporter chart 4.8.4, model `llama3.2:3b` (3.1 GB, 100% GPU). Needed two fixes and a manual resume of the first `up` (see GPU section). Teardown (`gpu-session.sh down` + `verify`) was run afterwards and passed (see below); a real reaper deletion was not exercised. |

**Result** values: `pass`, `pass with changes`, `fail`.

## Test checklist

For each environment, record whether these succeeded:

- [x] `./scripts/check-prerequisites.sh` (kind)
- [x] `kubectl apply -k manifests/overlays/<cpu|gpu>` (kind)
- [x] Model cache PVC bound (kind)
- [x] Pod Ready (startup and readiness probes pass) (kind)
- [x] Model-listing request returns expected output (kind)
- [x] Bounded inference request returns expected output (kind)
- [x] `./scripts/smoke-test.sh` (kind)
- [ ] `./scripts/cleanup.sh` (only the abort path has been exercised)

## Pinned versions

- Serving engine and image: `ollama/ollama:0.35.1`; resolved digest observed on arm64 kind: `sha256:292ee7945dfc3d5840a181f3ab86fedb1e66703e02c8af98b50f4da56b7e278c` (not pinned in the manifest)
- Model (CPU): `qwen2.5:0.5b`, Ollama model ID `a8b0c5157701`, 397 MB. The tag is mutable; this ID is observed, not enforced.
- Model (GPU): `llama3.2:3b`, Ollama model ID `a80c4f17acd5`, 3.1 GB, observed 100% on GPU.
- GPU stack: driver `nvidia-headless-580-server` 580.178.04, `nvidia-container-toolkit` 1.20.1-1, NVIDIA device plugin chart 0.20.1, dcgm-exporter chart 4.8.4.

## Static validation (no cluster or hosts)

| Date | Check | Result |
|---|---|---|
| 2026-10-07 | `shellcheck -x scripts/*.sh manifests/base/entrypoint.sh` | pass |
| 2026-10-07 | `yamllint manifests infra` | pass |
| 2026-10-07 | `kubectl kustomize manifests/overlays/{cpu,gpu}` | renders |
| 2026-10-07 | `ansible-lint`, `ansible-playbook --syntax-check` | pass |
| 2026-10-07 | `pulumi preview` (dummy token, local backend) | plans 2 resources, no errors |
| 2026-10-07 | K3s pin guard rejects anything but an exact `v1.36.x+k3sN` | pass (offline test) |
| 2026-10-07 | `check-prerequisites.sh` kubectl skew warning (simulated 1.34 client / 1.36 server) | pass |
| 2026-10-07 | `pulumi preview` with `gpuType`, plus non-GPU plan rejected | pass (dummy token) |
| 2026-10-07 | Ansible GPU role/add-on templates: lint, syntax-check, render | pass |
| 2026-10-07 | `validate-gpu.sh` on kind (no GPU): fails cleanly with a clear message | pass (mechanics only) |
| 2026-10-07 | `pulumi preview` base project (VPC, subnet, server, firewall) | pass (dummy token) |
| 2026-10-07 | `pulumi preview` GPU project against a stand-in base stack: only instance + firewall created | pass (dummy token) |
| 2026-10-07 | `gpu-session.sh` approval gating, failure report, teardown order, verify (stub CLIs + fake Linode API) | pass (no real cloud) |
| 2026-10-07 | `gpu-reaper.sh` selection rules and by-id deletion (fake Linode API) | pass (no real cloud) |
| 2026-10-07 | `gpu-session.sh plan` against Linode's real public pricing API | pass ($0.52/hr x 2 h = $1.04) |
| 2026-10-28 | Reaper role: ansible-lint, syntax-check, empty-token refusal; `up` refuses when the reaper timer is inactive (stubs) | pass (no real cloud, no systemd) |
| 2026-10-28 | Real `pulumi preview` + `pulumi up` of the base stack (VPC, subnet, g6-standard-4 server, firewall) in us-ord | pass; 5 resources, server running |
| 2026-10-28 | Base server inspected over SSH: VPC `eth1` auto-configured, distro kernel + headers present, key-only SSH | pass (read-only) |
| 2026-10-28 | Base bootstrap on the real server: K3s v1.36.5+k3s1 installed, `validate.yml` passes, lab kubeconfig works through the firewall (kubectl 1.34 vs server 1.36, skew warning only) | pass |
| 2026-10-28 | Found and fixed: flannel VXLAN bound to public eth0 instead of the VPC; fixed with `flannel-iface`, re-verified `flannel.1 local 10.0.0.10 dev eth1` | fixed |
| 2026-10-28 | Second base build on a real server (`pulumi up`, bootstrap, `validate.yml`): hostname `llm-lab-server` and K3s node name `llm-lab-server` (no more `localhost`), `/etc/hosts` entry, cloud-init `preserve_hostname`, managed prompt block, flannel on the VPC `eth1` from first boot | pass |
| 2026-10-28 | Reaper deployed to the real server via `playbooks/reaper.yml`: dry run proves token/API access, `systemd-analyze verify` clean, token file 0600 root-only and absent from units/journal, timer enabled, hardened service ran in execute mode (0 candidates, `Result=success`); `gpu-session.sh up`'s precondition (`is-active llm-gpu-reaper.timer`) passes | pass (no real deletion exercised) |
| 2026-10-28 | Third base build: the new server was handed the address of the destroyed GPU worker, so the bootstrap failed with a changed-host-key error. Confirmed IP reuse against Linode and Pulumi, dropped the stale pin, bootstrap and `validate.yml` then passed. `generate-inventory.sh` now ties pins to instance ids (tested with stand-in keys and on the live lab) | fixed |

## Baseline and what is still NOT validated

Baseline is Kubernetes 1.36 via K3s `v1.36.5+k3s1`. Validated: the CPU path on
kind (v1.34.0), the base lab and reaper install on a real server, and
(2026-10-28) a full GPU session on two real nodes running the same K3s version.

Still not validated, so none of it is claimed:

- **An unattended `up` from start to finish:** the first real run failed twice
  after provisioning and was resumed by hand (see below); a clean rerun is needed.
- **A real reaper deletion** of an expired instance (only the timer, the units and
  a zero-candidate execute run are verified).
- **The CPU workload on the Linode lab.** The CPU overlay is validated on kind and
  the lab on Linode (with the GPU workload), but the two have not been run
  together, even though the README's from-scratch path deploys exactly that.
- GPUs, regions, plans and clusters other than the one above.

## GPU lab validation (two nodes, K3s v1.36.5+k3s1): PASSED 2026-10-28

Run with `./scripts/validate-gpu.sh` (the final stage of `gpu-session.sh up`) on a
real `g2-gpu-rtx4000a1-s` worker in `us-ord`. Output: `GPU VALIDATION PASSED`.

| Check | Result |
|---|---|
| 1 same K3s version and Ready on both nodes | PASS (v1.36.5+k3s1) |
| 2 `nvidia` RuntimeClass | PASS |
| 3 GPU allocatable on the GPU node | PASS (`nvidia.com/gpu=1`) |
| 4 device plugin running on the GPU node | PASS |
| 5 inference pod on the GPU node, 1 GPU allocated | PASS |
| 6 `nvidia-smi` inside the pod | PASS (RTX 4000 Ada) |
| 7 inference request | PASS |
| 8 model loaded on the GPU | PASS (`llama3.2:3b`, 100% GPU) |
| 9 cross-node networking | PASS (client on the server node reached the service on the GPU node) |
| 10 metrics-server (`kubectl top nodes`) | PASS |
| 11 dcgm-exporter GPU metrics | PASS (3150 MiB framebuffer used, util series present) |

Also observed on the GPU node: flannel on the VPC interface (`local 10.0.0.20
dev eth1`), hostname preserved across the driver reboot, join-token file 0600.

**Bugs this run found (both fixed in the repo):**

| Symptom | Cause | Fix |
|---|---|---|
| Bootstrap failed immediately: `'k3s_version' is undefined` | The session inventory lives in `.lab/sessions/<id>/`, outside `infra/ansible`, so Ansible never loaded `group_vars` | `generate-inventory.sh` links `group_vars` next to a session inventory |
| K3s agent install failed: "Defaulted k3s exec command to 'agent' because K3S_URL is defined, but K3S_TOKEN or K3S_TOKEN_FILE is not defined" | The install script only checks the environment, not `config.yaml`, for the token | Join token written to a root-only file; `K3S_TOKEN_FILE` set for the installer and `token-file` in the config |

Both were invisible to the stub-based tests, because the stubs replaced the real
playbook run. The first `up` was resumed by running the playbook, the overlay
deploy and `validate-gpu.sh` by hand with the exact commands the script uses.

## GPU session teardown: PASSED 2026-10-28

`./scripts/gpu-session.sh down --session first` on the session above. Sequence as
run: delete namespace `llm-inference-gpu` (node still alive) → `pulumi destroy`
of the session stack (3 resources, 43 s; the instance itself 38 s) → delete the
stale Node object → remove the stack → `verify`. The script's `verify` passed all
four checks:

| Check | Result |
|---|---|
| GPU instance deleted | PASS (`GET` returns 404) |
| No tagged billable objects | PASS (tag listing: 0 objects) |
| Stack holds no resources | PASS (stack gone) |
| Base control plane intact | PASS (server still returns 200) |

Independent checks afterwards (direct API, kubectl, Pulumi): the session
firewall also returns 404; the account holds only its original resources plus the
lab's own server, VPC and base firewall; no new volumes; the cluster is back to one
node with no leftover PVs; the Pulumi GPU project has no stacks. Pods that were
bound to the deleted node showed as Running for under a minute, then were
garbage-collected. The idle GPU add-ons remain with 0 desired pods.

