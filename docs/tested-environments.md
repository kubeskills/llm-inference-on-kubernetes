# Tested environments

Only environments listed here have been verified. One live environment (kind) has been tested; see Results.

## Results

| Environment | Kubernetes version | Path (CPU/GPU) | Nodes / resources | Storage class | Date tested | Result | Notes |
|---|---|---|---|---|---|---|---|
| kind v0.30.0 on Docker Desktop 29.6.1 (arm64 host, VM 12 CPU / 8 GB) | v1.34.0 (`kindest/node:v1.34.0`) | CPU | 1 control-plane node | `standard` (rancher.io/local-path) | 2026-10-07 | pass | Fresh cluster `llm-lab`. Restart reused the cache (Ready in 7s, no model re-download). NetworkPolicy enforced: pod in `default` blocked, same-namespace pod allowed. amd64 not tested. |

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
- Model: `qwen2.5:0.5b`, Ollama model ID `a8b0c5157701`, 397 MB. The tag is mutable; this ID is observed, not enforced.

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

## Baseline and what is NOT yet validated

Baseline is Kubernetes 1.36 via K3s `v1.36.5+k3s1`. The only live run so far
used kind with Kubernetes v1.34.0 (CPU path). None of the following has been
validated, so none is claimed:

- K3s `v1.36.5+k3s1` with a GPU agent joined (the server alone is now running it)
- GPU driver, container runtime, and device allocation
- Inference on the GPU node
- Cross-node pod networking
- Monitoring (GPU and node metrics)

## GPU lab validation (two nodes, K3s v1.36.5+k3s1): NOT RUN

Record results from `./scripts/gpu-session.sh up ...` (which runs `./scripts/validate-gpu.sh`).
Only a full `GPU VALIDATION PASSED` counts as success.

| Check | Result |
|---|---|
| 1 same K3s version and Ready on both nodes | not run |
| 2 `nvidia` RuntimeClass | not run |
| 3 GPU allocatable on the GPU node | not run |
| 4 device plugin running on the GPU node | not run |
| 5 inference pod on the GPU node, 1 GPU allocated | not run |
| 6 `nvidia-smi` inside the pod | not run |
| 7 inference request | not run |
| 8 model loaded on the GPU | not run |
| 9 cross-node networking | not run |
| 10 metrics-server (`kubectl top nodes`) | not run |
| 11 dcgm-exporter GPU metrics | not run |
