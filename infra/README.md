# Infra: build the lab from scratch

This is where the from-scratch path in the [main README](../README.md#start-here-build-the-lab-from-scratch)
starts. It builds a disposable K3s lab on Linode in `us-ord` (Kubernetes 1.36
baseline, K3s `v1.36.5+k3s1` on every node), so you do not need a cluster of your
own. If you already have one, you can skip this directory; see
[Already have a cluster?](../README.md#already-have-a-cluster).

```text
BASE (persistent)                            GPU SESSION (ephemeral, on demand)
infra/pulumi/base  -> VPC, subnet,           infra/pulumi/gpu  -> GPU instance +
                      K3s server,                                 session firewall
                      base firewall          one stack per session: gpu-<id>
Ansible: bootstrap.yml                       reads base OUTPUTS only (StackReference)
default environment: NO GPU instance         Ansible: gpu-session.yml
```

| Tool | Owns | Does not touch |
|---|---|---|
| `pulumi/base` | VPC, subnet, server, base firewall | any GPU resource |
| `pulumi/gpu` (stack per session) | one GPU instance, one session firewall | base resources (read-only reference) |
| `ansible/` | OS prep, pinned K3s install, GPU runtime, lab kubeconfig | cloud resources |
| `../manifests` | the inference workload | hosts, cloud |

Pulumi never SSHes to anything. Ansible connects over SSH.

## Safety

- Use **dedicated, expiring Linode tokens** (one for Pulumi, one for the
  reaper), kept in the macOS Keychain and never written to a file. The scripts
  pass them to curl on stdin, not argv.
- **Decision (2026-10-28): the lab runs in an existing Linode account that also
  holds unrelated resources, and the operator accepted that risk** instead of
  using a separate account. A `linodes:read_write` reaper token can therefore
  delete any Linode in the account. Mitigations are in the code only: the
  reaper deletes an instance only if it has both the `llm-gpu-session` and
  `llm-inference-lab` tags, an `llm-gpu-` label, no `k3s-server` tag, and a
  passed expiry; Pulumi manages only resources it created.
- The lab kubeconfig is `.lab/kubeconfig` (gitignored, 0600), never merged into
  `~/.kube/config`. Scripts refuse to act on your current kubectl context.
- Firewalls accept SSH and the API only from `adminCidr` (`0.0.0.0/0` is
  rejected). Node-to-node traffic is admitted by **VPC subnet**, so a node added
  later needs no change to the base firewall.
- Access is key-only; no root password. First SSH contact is trust-on-first-use
  into `.lab/known_hosts` (Linode does not expose host keys out of band).

## 1. Build the persistent base (no GPU)

Billing starts at `pulumi up` (a `g6-standard-4` server is about $0.07/hr).

```bash
export LINODE_TOKEN=...
cd infra/pulumi/base
python3 -m venv venv && venv/bin/pip install -r requirements.txt
pulumi stack init lab
pulumi config set serverType g6-standard-4 --stack lab
pulumi config set adminCidr <your-public-ip>/32 --stack lab
pulumi config set sshPublicKey "$(cat ~/.ssh/id_ed25519.pub)" --stack lab
pulumi preview --stack lab
pulumi up --stack lab

cd ../../..
BASE_STACK=lab ./scripts/generate-inventory.sh
cd infra/ansible
ansible-playbook playbooks/bootstrap.yml
ansible-playbook playbooks/validate.yml
```

The base stack exports `server_instance_id`, `vpc_subnet_id`, etc., which the
GPU stack reads.

## 2. On-demand GPU session

The GPU worker exists only between an approved `up` and a `down`. Everything
names the session explicitly; the Pulumi stack is always `gpu-<session>`.

```bash
# See the plan, hourly rate and estimated cost. Creates nothing, asks nothing.
./scripts/gpu-session.sh plan --plan g2-gpu-rtx4000a1-s --hours 2

# Provision (interactive only: you type the session id to approve the cost).
./scripts/gpu-session.sh up --session s1 --plan g2-gpu-rtx4000a1-s --hours 2 \
  --base-stack organization/llm-inference-infra/lab \
  --admin-cidr 203.0.113.4/32 --ssh-public-key "$(cat ~/.ssh/id_ed25519.pub)"

./scripts/gpu-session.sh status --session s1
./scripts/gpu-session.sh down   --session s1     # deletes the instance
./scripts/gpu-session.sh verify --session s1     # re-check nothing is billing
```

`up` shows the plan, hourly rate, requested duration and estimated compute cost,
runs `pulumi preview`, then waits for you to type the session id. Only then does
it provision, bootstrap (driver, container toolkit, K3s agent, device plugin,
dcgm-exporter), deploy `manifests/overlays/gpu` into namespace
`llm-inference-gpu`, and run `scripts/validate-gpu.sh`. It reports **ACTIVE**
only if that passes. On any failure it prints which stage failed, the instance
id and stack contents, and the exact `down` command; it never auto-destroys and
never claims success.

`down` asks for approval, then in order: deletes the `llm-inference-gpu`
namespace (while the node is alive, so the volume is cleaned), destroys the
session stack (**the instance is deleted, not stopped**), deletes the stale
Node object, removes the stack, and runs `verify`: the instance id must return
404, the session tag must list no billable objects, the stack must hold no
resources, and the base server must still exist.

No volume or other persistent GPU storage is created. The model cache lives on
the instance disk and disappears with it (the model is re-pulled each session).

### Expiry is enforced by an independent process on the control plane

Expiry tags (`llm-exp-<epoch>`) delete nothing. `scripts/gpu-reaper.sh` is the
enforcement: it needs only a token (no Pulumi, Ansible, session files, or
cluster access), considers only instances tagged `llm-gpu-session`, never touches
anything tagged `k3s-server`, and deletes expired ones **by instance id**.
It runs on the control-plane server as a systemd timer (every 5 minutes), so it
keeps enforcing while your laptop is off.

Install it once, after the base bootstrap:

```bash
# Dedicated Linode PAT from the LAB account (not your Pulumi token),
# scope linodes:read_write ONLY. Held in your shell; never written to the repo.
export REAPER_LINODE_TOKEN=...
cd infra/ansible && ansible-playbook playbooks/reaper.yml
```

The role installs `curl`/`jq`, copies the script to `/opt/llm-lab/scripts`,
writes the token to `/etc/llm-lab/reaper.env` (root-only, mode 0600), installs a
hardened `llm-gpu-reaper.service` (dynamic user, no capabilities, outbound IP
only) and `llm-gpu-reaper.timer`, then proves the token works with a **dry run**
(it deletes nothing) before enabling the timer. To rotate the token, export the
new one and re-run the playbook.

`gpu-session.sh up` refuses to provision unless `llm-gpu-reaper.timer` is active
on the server. There is no bypass flag.

By hand (dry run is the default):

```bash
./scripts/gpu-reaper.sh               # lists what would be deleted
./scripts/gpu-reaper.sh --execute     # deletes expired GPU session instances
```

After a reaper deletion, run `gpu-session.sh down --session <id>` to reconcile
Pulumi and Kubernetes state. Check the timer on the server with
`systemctl list-timers llm-gpu-reaper.timer` and `journalctl -u llm-gpu-reaper`.

**Trade-offs of a token on a public host.** Anyone who gets root on the server
gets this token, and a `linodes:read_write` token can delete **any** instance in
the account, including the server itself. The script's tag filters protect
against bugs, not against a compromised host. That is why the token must be
dedicated and rotated. In this setup the account is NOT lab-only (see the
decision above), so a compromised server could also delete unrelated Linodes. A failed run (for example a revoked token) shows up only in the journal
and `systemctl --failed`; nothing alerts you.

## Requirement map

| # | Requirement | Where |
|---|---|---|
| 1 | Base creates no GPU | `pulumi/base` and `bootstrap.yml` have no GPU resource or play |
| 2 | Separate project and stack | `pulumi/gpu`, stack `gpu-<session>` |
| 3 | GPU reads base, never owns it | `StackReference`; preview shows only session resources |
| 13 | Expiry enforced independently | `gpu-reaper.sh` as a systemd timer on the server; `up` refuses if it is not active |
| 4 | Show plan, rate, duration, cost | `gpu-session.sh plan`/`up` (Linode public pricing API) |
| 5 | Explicit approval | typed session id on a tty; no bypass flag |
| 6 | Join, validate network, GPU, inference | `gpu-session.yml` + `validate-gpu.sh` |
| 7 | Teardown deletes the instance | `pulumi destroy`, then 404 check |
| 8 | Preserve control plane and network | `down` never targets the base stack; verify checks it |
| 9 | No persistent GPU storage | none created; tag listing confirms |
| 10 | Verify no billable resources remain | `verify` (instance 404, tag listing, stack, base) |
| 11 | Report and clean up failures | stage report with instance id and `down` command |
| 12 | Explicit stack and resource ids | `--session`, `--stack gpu-<id>`, instance id from the record |

## Status and unverified risks

Tested with stubs and a fake Linode API: approval gating, failure reporting,
teardown order, verification (including a destroy that fails to delete), the
reaper's selection rules, and `pulumi preview` for both projects.

**Run for real (see [tested-environments.md](../docs/tested-environments.md)):**
the base stack, the K3s bootstrap and validation, the hostname/prompt settings,
the reaper install, and (2026-10-28) a full GPU session: provisioning, the NVIDIA
driver and toolkit, the device plugin, cross-node traffic, GPU inference, and all
11 `validate-gpu.sh` checks. That first `up` failed twice after provisioning (two
bugs, now fixed) and was resumed by hand. Teardown (`down` + `verify`) then ran
for real and passed. **Not yet run for real:** an unattended `up` from start to
finish, and a reaper deletion.

- **Reaper: verified on a real server (2026-10-28).** The unit files pass
  `systemd-analyze verify`; the hardened service (dynamic user, root-only
  `EnvironmentFile`, syscall filter) ran successfully under the timer in execute
  mode and found 0 candidates; the token file is 0600 root-only and absent from
  unit files and logs; the GNU `date` fallback works. Not yet verified: an actual
  **deletion** of an expired instance on Linode (only tested against a fake API),
  and that `linodes:read_write` is the minimum scope.
- **VPC networking inside the guest: verified on the base server (2026-10-28).**
  Ubuntu configures the VPC interface automatically (`eth1` = `10.0.0.10/24`,
  on-link, default route stays on the public `eth0`). **K3s does NOT bind
  flannel to the VPC interface just because `node-ip` is the VPC address**: on
  the first real run VXLAN came up on the public `eth0`, which the firewall
  would have blocked. The configs now set `flannel-iface` (derived from the
  host's own VPC address), and the fixed server shows `flannel.1 local
  10.0.0.10 dev eth1`. Verified on the GPU node too (`local 10.0.0.20 dev
  eth1`), and by a client on the server node reaching a service on the GPU node.
- **Host and node names.** The VMs boot as `localhost`. The `common` role sets
  the hostname (like `hostnamectl set-hostname`) before K3s is installed:
  `llm-lab-server` for the server and `llm-<inventory name>` (e.g. `llm-gpu-0`)
  for agents, and K3s `node-name` is set to the same value so nodes cannot
  collide. The role also adds a `127.0.1.1` entry to `/etc/hosts` (no `sudo`
  resolution warning) and tells cloud-init to preserve the hostname. Verified on
  a real server: the hostname, K3s node name, `/etc/hosts` entry and the
  cloud-init file are all in place after bootstrap, and the GPU node kept its
  name across the driver reboot. Changing the
  hostname of an already-bootstrapped server would rename its K3s node; rebuild
  instead.
- `interface_generation="legacy_config"` is set explicitly because the account
  default may be the new Linode Interfaces generation.
- The distro kernel (`6.8.0-134-generic`) with matching headers let the DKMS
  driver build and load on the GPU node (`nvidia-headless-580-server` 580.178.04).
  `g2-gpu-rtx4000a1-s` was in stock in `us-ord` and no deposit was requested on
  this account; a newer account may still be asked for one.
- One GPU worker at a time (fixed VPC address `10.0.0.20`).
- The tag-listing check needs an `account:read_only` token on an unrestricted
  account; if unavailable, `verify` fails rather than assuming success.
- `Instance.ip_address` is deprecated in pulumi-linode 6.7.0 (warning only; the
  SDK has no replacement output).
- The K3s install script is downloaded over HTTPS but not checksum-pinned here.
- dcgm-exporter runs as root with `SYS_ADMIN` (chart default).
- DRA and workload-aware scheduling are not configured anywhere.

## Tear down everything

```bash
./scripts/gpu-session.sh down --session <id>   # any live GPU session first
cd infra/pulumi/base && pulumi destroy --stack lab
rm -rf .lab                                    # kubeconfig, known_hosts, sessions
```

`scripts/cleanup.sh` only removes Kubernetes resources, not instances.
