# Troubleshooting

Each entry is **symptom, cause, how to check, fix**. Two labels say how much to
trust it:

- **observed**: this happened while building the project, and the fix was verified.
- **expected**: predicted from the design or from upstream docs, but not yet seen
  here. Treat the fix as a lead, not a guarantee. Everything GPU-related is in
  this group until the GPU path has run on real hardware (see
  [tested-environments.md](tested-environments.md)).

## The workload

### A script says "no target cluster selected" (observed)
Scripts never fall back to your current kubectl context. Choose one:
```bash
kubectl config get-contexts
export KUBE_CONTEXT=<your-context>      # existing cluster
```
or build the lab, which writes `.lab/kubeconfig`. For a different kubeconfig
file (for example a local kind cluster), set `LAB_KUBECONFIG=<file>`.

### The pod is not Ready for several minutes on first start (observed, usually normal)
Readiness means the model is **present**, not that the process is up. The first
start pulls the image and the model (397 MB for the default CPU model), and the
startup probe allows about 10 minutes.
```bash
kubectl -n llm-inference describe pod -l app=llm-inference   # events: image pull?
kubectl -n llm-inference logs deploy/llm-inference            # model pull progress
kubectl -n llm-inference exec deploy/llm-inference -- ollama list
```
If it never becomes Ready: check the pull can reach the internet (egress is
limited to DNS and port 443 by the NetworkPolicy), and that `MODEL_NAME` in the
overlay is a real model tag.

### The PVC stays Pending (expected)
The default StorageClass uses `WaitForFirstConsumer`, so the claim binds only once
the pod is scheduled. If the **pod** is also Pending, look for a missing default
StorageClass (`kubectl get storageclass`; `check-prerequisites.sh` warns about
this). Set `storageClassName` in `manifests/base/model-cache.yaml` if your
cluster has none.

### A client in another namespace cannot reach the service (observed, by design)
The NetworkPolicy only admits pods in the **same namespace** on port 11434. Test
from inside `llm-inference`, or use `kubectl port-forward`, which is not affected.

### `smoke-test.sh` fails with "port-forward exited" (expected)
Local port 18434 is already in use. Pick another: `LOCAL_PORT=18500 ./scripts/smoke-test.sh`.

### `kubectl` prints a version-skew warning (observed)
A 1.34 client against a 1.36 server works but is outside the supported +/-1 minor
skew; `check-prerequisites.sh` warns about it. Upgrade kubectl when convenient.

### `cleanup.sh` asks me to type something (by design)
It deletes the whole namespace including the model-cache PVC, so you must type the
context name it prints. It never deletes cloud instances; that is `pulumi destroy`.

## The lab: Pulumi

### `preview` or `up` rejects my config (observed)
The messages are deliberate guards:
- `region must be us-ord`: the lab is fixed to `us-ord`.
- `adminCidr must be your own address, not the whole internet`: use a `/32`.
- `sessionId must be lowercase letters/digits/dashes, max 24`.
- `gpuType must be a GPU plan`: use a `g1-gpu-*` or `g2-gpu-*` slug.

### `pulumi up` fails within seconds, before creating anything (observed)
`pulumi preview` passes even with **no token or a fake one**, so a bad token only
shows up as a failure at the first real API call (the VPC). Linode logs no event
for it. Likely causes: the token is not exported in **this** shell (each terminal
starts without it), it still contains the docs' `...` placeholder, it expired, or
it lacks read/write for **VPCs** or **Firewalls** (a Linodes-only token can read
VPCs but gets 401 creating one). Check before `up`:
```bash
./scripts/check-linode-token.sh      # run from the repo root; creates nothing
```
It probes each create with an invalid body (400 means allowed, 401 means missing
scope). The Pulumi programs also stop early with `LINODE_TOKEN is not set`. A
failed `up` like this leaves the stack with no Linode resources, so just rerun.

### "LINODE_TOKEN is not set" or an authentication error (observed)
Export the token for that command only; do not write it to a file. Each shell
starts fresh, so exporting in another terminal does not help.

### `ip_address is deprecated` warning (observed, harmless)
pulumi-linode 6.x deprecates `Instance.ip_address` but exposes no replacement
output, so the warning is expected.

### I lost SSH or API access after my IP changed (expected)
The firewall admits only `adminCidr`. Update the config and apply:
```bash
cd infra/pulumi/base
pulumi config set adminCidr <new-ip>/32 --stack lab
pulumi up --stack lab
```
(or use the Linode Cloud Manager firewall page for an immediate fix).

### `pulumi preview --destroy` says "unknown flag" (observed)
Older Pulumi CLIs lack it. Use `pulumi destroy --preview-only --stack <stack>`.

## The lab: Ansible and K3s

### "Ansible requires blocking IO on stdin/stdout/stderr" (observed)
Seen when output goes to a non-blocking handle (for example some IDE terminals or
tool shells). Pipe the output: `ansible-playbook ... 2>&1 | cat`.

### `REMOTE HOST IDENTIFICATION HAS CHANGED` during the bootstrap (observed twice)
Linode **reuses public IPs**: a rebuilt machine can inherit a destroyed one's
address while `.lab/known_hosts` still pins the old key, and the playbook's SSH wait
fails with "Host key verification failed". It looks like a man-in-the-middle warning
but, in both cases seen so far, it was IP reuse. Before removing anything, confirm
the address now belongs to your new server:
```bash
cd infra/pulumi/base && pulumi stack output server_ip server_instance_id --stack lab
```
and that the same `server_ip` and instance id appear in the Linode Cloud Manager. Then
drop only the stale pin (the lab keeps its own file, not `~/.ssh/known_hosts`):
```bash
ssh-keygen -R <server-ip> -f .lab/known_hosts
```
`scripts/generate-inventory.sh` now does this for you: it records which **instance
id** owns each pinned address and forgets a pin only when that id changes (or was never
recorded), so a pin for an unchanged server is kept and a swapped host is still caught.
Regenerate the inventory (`BASE_STACK=lab ./scripts/generate-inventory.sh`) before
the bootstrap. First contact is trust-on-first-use; the bootstrap prints the
fingerprint read from the server so you can compare it. (A "Non UTF-8 encoded data"
warning next to this error is just the emoji in the repo path and is harmless.)

### `k3s_version must be an exact v1.36.x+k3sN release` (observed)
The guard rejects channels like `stable` or `latest` and any non-1.36 version.
Set an exact release in `infra/ansible/group_vars/all.yml` after checking it
exists on the k3s-io/k3s GitHub releases page and is not a pre-release.

### Pods on different nodes cannot talk (observed on the server; cross-node expected)
K3s bound flannel's VXLAN to the **public** interface even though `node-ip` was
the VPC address, so the firewall (which admits VXLAN only from the VPC subnet)
dropped pod traffic. Single-node clusters hide this. Check on the node:
```bash
ip -d link show flannel.1 | grep -oE 'vxlan id [0-9]+ local [0-9.]+ dev [a-z0-9]+'
# want:  local 10.0.0.x dev eth1      (the VPC address and interface)
```
The configs set `flannel-iface`. If you see the public interface, check
`/etc/rancher/k3s/config.yaml`, then `systemctl restart k3s` (or `k3s-agent`).

### The server node is called `localhost`, or a new node is rejected as a duplicate (observed)
VMs boot as `localhost`. The `common` role sets the hostname before K3s installs
and K3s uses the same name. **Do not change the hostname of a running cluster**; it
renames the K3s node. Rebuild instead.

## GPU sessions (`scripts/gpu-session.sh`)

### `up` refuses to start (observed with test doubles, by design)
- `up must be run interactively on a terminal`: approval is a typed session id;
  run it from a real terminal, not a script or tool shell.
- `the expiry reaper is not active on the control plane`: install it first
  (`REAPER_LINODE_TOKEN=... ansible-playbook playbooks/reaper.yml` in `infra/ansible`).
- `another session is not destroyed`: only one GPU worker at a time; run
  `down --session <id>` for the old one.
- `session <id> already exists`: pick a new id, or `down` the old record.

### Bootstrap fails with `'k3s_version' is undefined` (observed, fixed)
Ansible loads `group_vars` from next to the inventory file. A session inventory
lives in `.lab/sessions/<id>/`, outside `infra/ansible`, so none of the group
variables were found. `generate-inventory.sh` now links `group_vars` next to it. If
you see this on an older checkout, regenerate the session inventory:
`BASE_STACK=lab ./scripts/generate-inventory.sh --session <id>`.

### The K3s agent install fails with "Defaulted k3s exec command to 'agent' because K3S_URL is defined, but K3S_TOKEN or K3S_TOKEN_FILE is not defined" (observed, fixed)
The install script checks only its **environment** for the token, not
`config.yaml`. The agent role now writes the join token to a root-only file
(`/etc/rancher/k3s/agent-token`) and sets `K3S_TOKEN_FILE` for the installer plus
`token-file` in the config. Rerun the playbook; the earlier steps are idempotent.

### `up` fails partway (observed on a real session)
The failure report names the stage, lists the stack's resources and the instance
id, and prints the exact cleanup command. **Billing continues until the instance
is deleted.** The instance and firewall already exist at that point, so you can fix
the cause and rerun the failed stage by hand (inventory, playbook, overlay,
`validate-gpu.sh`) instead of tearing down and paying to start over; there is no
`resume` command yet.
```bash
./scripts/gpu-session.sh status --session <id>
./scripts/gpu-session.sh down   --session <id>
```
It never auto-destroys, so a failed session keeps costing money until you act (or
the reaper removes it after expiry).

### `verify` fails (observed with test doubles)
It tells you which check failed:
- instance still returns 200: the instance was not deleted; rerun `down`, or check
  the Linode console.
- `tag listing unavailable`: the Pulumi token needs `account:read_only` (and an
  unrestricted account) for the tag check. `verify` fails rather than assume.
- stack still holds resources: `pulumi destroy --stack gpu-<id>` in `infra/pulumi/gpu`.

### After `down`, pods still show as Running for a moment (observed)
Deleting the Node leaves its pods listed until Kubernetes garbage-collects the
orphans, which took under a minute. Nothing to do; recheck with
`kubectl get pods -A -o wide`.

### The reaper deleted my instance, but Pulumi and Kubernetes still list it (expected)
The reaper only deletes the cloud instance. Reconcile with
`./scripts/gpu-session.sh down --session <id>`.

### The reaper does nothing, or fails silently (expected)
On the server:
```bash
systemctl list-timers llm-gpu-reaper.timer
journalctl -u llm-gpu-reaper -n 50
systemctl --failed
```
A revoked or expired reaper token shows up only here; nothing alerts you. Rotate by
exporting the new token and rerunning `playbooks/reaper.yml`. A dry run on the
server deletes nothing: `/opt/llm-lab/scripts/gpu-reaper.sh`.

### Linode refuses to create the GPU instance (expected)
New or low-spend accounts may need a deposit before deploying GPU Linodes; contact
Linode support. Also confirm the plan is in stock in `us-ord`.

### The GPU role fails to install the driver (expected)
The driver package builds a kernel module with DKMS and needs headers for the
**running** kernel (present on the base image; not yet confirmed on the GPU
node). Check `dkms status` and `journalctl` on the node, and that the node was
rebooted after the driver install.

### K3s did not pick up the NVIDIA runtime (expected)
K3s detects `nvidia-container-runtime` **when it starts**, so the GPU role must run
before the agent. Check on the GPU node:
```bash
which nvidia-container-runtime
grep nvidia /var/lib/rancher/k3s/agent/etc/containerd/config.toml
```
If missing, the toolkit was installed after the agent started; install it and
`systemctl restart k3s-agent`.

### The GPU pod stays Pending (expected)
```bash
kubectl -n llm-inference-gpu describe pod -l app=llm-inference   # scheduling events
kubectl get node -l nvidia.com/gpu.present=true                  # is the node labelled?
kubectl get runtimeclass nvidia
kubectl get node <gpu-node> -o jsonpath='{.status.allocatable.nvidia\.com/gpu}'
kubectl -n nvidia-device-plugin get pods -o wide
```
Common causes: the node label is missing (set by the agent config), no
`nvidia` RuntimeClass, or the device plugin is not running on the GPU node so no
`nvidia.com/gpu` is advertised.

### `validate-gpu.sh` reports a failed check (expected)
The checks run in order and each prints a reason. The first failure is usually the
cause of the ones after it. Do not document the GPU path as working unless it
ends with `GPU VALIDATION PASSED`.

## Quoting paths

If you clone into a directory whose path contains spaces or non-ASCII characters,
quote every path in commands. The generated inventory already
quotes the `known_hosts` path for SSH.
