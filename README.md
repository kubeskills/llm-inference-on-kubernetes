# LLM Inference on Kubernetes

Deploy a small language model on Kubernetes, send an inference request,
and investigate its startup and runtime behavior.

**This repo assumes you are starting from scratch.** You do not need an existing
Kubernetes cluster: `infra/` builds a disposable one for you on Linode, and the
rest of the repo deploys onto it. If you already have a cluster, there is a
shorter route; see [Already have a cluster?](#already-have-a-cluster).

## Status

Work in progress. The CPU workload is validated on kind, and the Linode lab (with
the GPU workload and teardown) on real hardware; see
[tested environments](docs/tested-environments.md). **The CPU workload on the Linode
lab itself has not been run yet**, and an unattended GPU `up` and a real reaper
deletion are still unproven.

## What you will learn

- Build a Kubernetes cluster from nothing, as code (Pulumi and Ansible).
- Deploy a real inference service.
- Store and reuse model artifacts.
- Configure startup and readiness checks.
- Access the model through a Kubernetes Service.
- Add a GPU worker on demand, and tear it down so it stops billing.
- Diagnose common deployment failures.
- Remove everything you created.

## Architecture

See [the architecture guide](docs/architecture.md).

## Start here: build the lab from scratch

### What you need

- A **Linode account** and an API token for it. New accounts may need a deposit
  before GPU instances are allowed. The lab runs in `us-ord` only.
- A **Pulumi account** and the Pulumi CLI. The examples keep stack state in
  Pulumi Cloud.
- On your machine: **Python 3**, **Ansible**, **kubectl** (within one minor
  version of 1.36 to avoid skew warnings), **jq**, **curl**, and an SSH key pair
  loaded in your `ssh-agent`.
- **Your public IP address**: the lab's firewall admits only that address to SSH
  and the Kubernetes API.

### What it costs

The lab server (`g6-standard-4`, 4 vCPU / 8 GB) bills about **$0.07/hour**
(roughly $52 a month) from the moment you create it until you destroy it. An
optional GPU session adds about **$0.52/hour** while it exists. Tear down when you
are done; see [Costs and cleanup](#costs-and-cleanup).

### 1. Create the server

Details and safety notes are in [infra/README.md](infra/README.md).

```bash
export LINODE_TOKEN=...                 # your Linode token, for this shell only
cd infra/pulumi/base
python3 -m venv venv && venv/bin/pip install -r requirements.txt
pulumi stack init lab
pulumi config set serverType g6-standard-4 --stack lab
pulumi config set adminCidr <your-public-ip>/32 --stack lab
pulumi config set sshPublicKey "$(cat ~/.ssh/id_ed25519.pub)" --stack lab
pulumi preview --stack lab              # read-only: shows what will be created
pulumi up --stack lab                   # first billable step
```

This creates a VPC, a subnet, one server and a firewall. It creates no GPU
resource.

### 2. Install Kubernetes on it

```bash
cd ../../..                             # back to the repo root
BASE_STACK=lab ./scripts/generate-inventory.sh
cd infra/ansible
ansible-playbook playbooks/bootstrap.yml
ansible-playbook playbooks/validate.yml
cd ../..
```

`bootstrap.yml` installs K3s `v1.36.5+k3s1` and writes a kubeconfig to
`.lab/kubeconfig`. When it finishes it prints the server's public IP and the exact
`ssh` command, so you can log in. If Ansible complains about blocking IO, see the
[troubleshooting guide](docs/troubleshooting.md).

### 3. Deploy the CPU workload

From here on, the scripts find the lab automatically through `.lab/kubeconfig`.

```bash
./scripts/check-prerequisites.sh
kubectl --kubeconfig .lab/kubeconfig apply -k manifests/overlays/cpu
./scripts/smoke-test.sh
```

See [Deploy and validate](#deploy-and-validate) for what to expect.

### 4. Optional: add a GPU worker for one session

A GPU session is time-boxed and approved by you. `gpu-session.sh` shows the plan,
hourly rate and estimated cost, and waits for you to type the session id before it
creates anything. It refuses to start until the expiry reaper is installed on the
server (a separate Linode token, installed with
`REAPER_LINODE_TOKEN=... ansible-playbook playbooks/reaper.yml` in `infra/ansible`).
The full steps and the safety model are in
[infra/README.md](infra/README.md#2-on-demand-gpu-session).

```bash
./scripts/gpu-session.sh plan --plan g2-gpu-rtx4000a1-s --hours 1   # cost only
```

### 5. Clean up

Do this when you are finished, or the server keeps billing. See
[Costs and cleanup](#costs-and-cleanup).

## Already have a cluster?

You can skip `infra/` entirely. The workload is intended to run on any standard
Kubernetes cluster (kind, minikube, Docker Desktop, k3d, a managed service, or a
self-managed install). Only the environments in
[tested environments](docs/tested-environments.md) have been verified.

1. Name the cluster you intend to use. The scripts never fall back to your
   current context:

   ```bash
   kubectl config get-contexts
   export KUBE_CONTEXT=<your-context>
   ```

2. Check prerequisites (kubectl access, a default StorageClass or an edit to
   `manifests/base/model-cache.yaml`):

   ```bash
   ./scripts/check-prerequisites.sh
   ```

3. Deploy and validate:

   ```bash
   kubectl --context "$KUBE_CONTEXT" apply -k manifests/overlays/cpu
   ./scripts/smoke-test.sh
   ```

## Choose a workload path

| | CPU | GPU |
|---|---|---|
| Configuration | `manifests/overlays/cpu/` | `manifests/overlays/gpu/` |
| Model (default) | `qwen2.5:0.5b` (397 MB) | `llama3.2:3b` (3.1 GB) |
| Needs | any cluster | a node with an NVIDIA GPU, driver, container toolkit and device plugin |
| From scratch | step 3 above | step 4 above (`gpu-session.sh up`), which builds all of that for you |
| Namespace | `llm-inference` | `llm-inference-gpu` |

On your own cluster, the GPU overlay also needs the NVIDIA components installed
and a `nvidia` RuntimeClass; `infra/` shows one way to set them up on K3s.

## Deploy and validate

```bash
./scripts/smoke-test.sh
```

It waits for the rollout, lists models, and sends a bounded inference request
(`num_predict` capped at 16). Success: the script prints `smoke test PASSED` and
exits 0.

Abridged output from the kind run (the model reply varies):

```text
model: qwen2.5:0.5b
--- model listing
qwen2.5:0.5b
--- bounded inference (num_predict=16)
response: Greetings.
smoke test PASSED
```

First start downloads the image and the model, so allow several minutes. Restarts
reuse the cache on the PVC. For the GPU path, `gpu-session.sh up` runs a longer
validation (`scripts/validate-gpu.sh`, 11 checks) and only reports success if all
of them pass.

## Troubleshooting

See [the troubleshooting guide](docs/troubleshooting.md).

## Costs and cleanup

Remove the workload from the cluster (it asks you to type the context name):

```bash
./scripts/cleanup.sh
```

That removes Kubernetes resources only. **It does not delete cloud instances.**
To stop all billing for the from-scratch lab:

```bash
# if a GPU session is running, end it first (it asks for approval)
./scripts/gpu-session.sh down --session <id>

cd infra/pulumi/base
pulumi destroy --stack lab              # deletes the server, firewall, subnet and VPC
```

Then confirm in the Linode Cloud Manager that no instances from the lab remain.

## Tested environments

See [tested environments](docs/tested-environments.md).

## Article and video

Add publication links after release.

## Limitations

This is a teaching environment, not a highly available production platform.

## Contributing

Contributions are welcome. The most useful ones right now are results from
environments not yet in [tested environments](docs/tested-environments.md),
fixes to the docs, and validation of the GPU path beyond the one session so far.
See [CONTRIBUTING.md](CONTRIBUTING.md) for the ground rules and how to test a
change.

## License

To be selected.
