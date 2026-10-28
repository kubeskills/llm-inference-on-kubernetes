# LLM Inference on Kubernetes

Deploy a small language model on Kubernetes, send an inference request,
and investigate its startup and runtime behavior.

## Status

Work in progress. Commands and manifests are not yet validated.

## What you will learn

- Deploy a real inference service.
- Store and reuse model artifacts.
- Configure startup and readiness checks.
- Access the model through a Kubernetes Service.
- Diagnose one common deployment failure.
- Remove the lab resources.

## Architecture

See [the architecture guide](docs/architecture.md).

## Start here: I already have a working Kubernetes cluster

This is the default path. **You can skip the `infra/` directory entirely.**
The lab is intended to run on any standard Kubernetes cluster, such as a
local cluster (kind, minikube, Docker Desktop, k3d), a managed service, or
a self-managed install. Only the environments listed in
[tested environments](docs/tested-environments.md) have been verified.
`infra/` is one optional way to get a cluster, not part of the lab itself.

1. Name the cluster you intend to use. The scripts never fall back to your
   current context:

   ```bash
   kubectl config get-contexts
   export KUBE_CONTEXT=<your-context>
   ```

2. Check prerequisites:

   ```bash
   ./scripts/check-prerequisites.sh
   ```

3. Jump to [Choose a lab path](#choose-a-lab-path), then
   [Deploy](#deploy) and [Validate](#validate).

Do not have a cluster yet? See
[Optional: provision a cluster](#optional-provision-a-cluster).

## Prerequisites

To be confirmed through testing:

- A working Kubernetes cluster and `kubectl` access to it.
- Kubernetes and kubectl versions.
- A default StorageClass (or edit `manifests/base/model-cache.yaml`).
- Serving engine and image digest.
- Model identifier and pinned revision.
- CPU, system memory, and disk requirements.
- GPU prerequisites for the optional GPU path.

## Choose a lab path

### CPU

Configuration: `manifests/overlays/cpu/`

### GPU

Configuration: `manifests/overlays/gpu/`

The GPU path assumes an existing, validated GPU-enabled Kubernetes node.
GPU-node provisioning is outside this initial lab.

## Deploy

Tested on kind only (see [tested environments](docs/tested-environments.md)):

```bash
kubectl --context "$KUBE_CONTEXT" apply -k manifests/overlays/cpu
```

The GPU overlay is a placeholder and is not part of this release.

## Optional: provision a cluster

Only needed if you have no cluster. `infra/` provisions hosts with Pulumi
and installs k3s with Ansible; see [infra/README.md](infra/README.md).
Afterwards, continue from step 1 of
[Start here](#start-here-i-already-have-a-working-kubernetes-cluster).

## Validate

```bash
./scripts/smoke-test.sh
```

It waits for the rollout, lists models, and sends a bounded inference request
(`num_predict` capped at 16). Success: the script prints
`smoke test PASSED` and exits 0.

Abridged output from the kind run (the model reply varies):

```text
model: qwen2.5:0.5b
--- model listing
qwen2.5:0.5b
--- bounded inference (num_predict=16)
response: Greetings.
smoke test PASSED
```

First start downloads the image and the 397 MB model, so allow several
minutes. Restarts reuse the cache on the PVC.

## Troubleshooting

See [the troubleshooting guide](docs/troubleshooting.md).

## Costs and cleanup

The workload creates one namespace, a 20Gi PVC, and one Deployment. Remove
it with `./scripts/cleanup.sh` (asks you to type the context name).
The optional `infra/` lab creates billable Linode instances; see
[infra/README.md](infra/README.md).

Kubernetes cleanup does not imply that cloud instances or separately
billed storage have been deleted.

## Tested environments

See [tested environments](docs/tested-environments.md).

## Article and video

Add publication links after release.

## Limitations

This is a teaching environment, not a highly available production platform.

## License

To be selected.