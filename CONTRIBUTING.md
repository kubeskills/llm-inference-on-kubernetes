# Contributing

Contributions are welcome, from typo fixes to results on a cluster we have not
tried. This is a teaching repo, so clarity and honesty about what has actually
been tested matter more than feature count.

## Where help is most useful

- **Test results from other environments.** The workload is intended to run on
  any standard Kubernetes cluster, but only what is listed in
  [docs/tested-environments.md](docs/tested-environments.md) has been verified.
  A new row (cluster type and version, CPU or GPU path, date, result, notes) is a
  real contribution, including a failure.
- **Validating the GPU path on real hardware.** It is built and statically
  checked but has not run on a GPU yet.
- **Docs.** `docs/troubleshooting.md` is still a stub; real failure modes you hit
  are exactly what it needs.
- **Other clusters and providers**, as long as the default path (an existing
  cluster, no `infra/`) keeps working.

For anything larger than a small fix, please open an issue first so we can agree
on the approach before you spend time on it.

## Ground rules

- **Never claim what you have not run.** If something is untested, say so in the
  docs, the way the existing text does. A passing lint is not a passing test.
- **Pin and verify versions.** Image tags, chart versions and provider versions
  must be exact (never `latest`) and checked against official docs or the
  registry. Do not invent API fields, Helm values or flags.
- **Kubernetes manifests** must set `resources.requests` and `resources.limits`,
  pin the image tag, include a `NetworkPolicy` for any new workload, and run as
  non-root (`runAsNonRoot`).
- **No secrets or real environment details** in commits: tokens, kubeconfigs,
  real IPs, account or instance ids, host fingerprints. Generated files are
  already gitignored; check `git status` before committing.
- **Keep the safety properties of the GPU lifecycle.** Please discuss in an issue
  before changing any of these: typed cost approval before anything billable, no
  GPU resources in the base stack, deleting (not stopping) on teardown with a
  verification step, and the independent expiry reaper with its tag and label
  guards.
- **Scripts must work on macOS bash 3.2 and Linux.** In particular, expanding an
  empty array under `set -u` fails on bash 3.2, and `set -e` is ignored inside
  functions called from `||`.

## Checking a change

There is no unit-test suite. Run the linters and render the manifests:

```bash
shellcheck -x scripts/*.sh manifests/base/entrypoint.sh
yamllint manifests infra
black --check infra/pulumi/base/__main__.py infra/pulumi/gpu/__main__.py
(cd infra/ansible && ansible-lint)
kubectl kustomize manifests/overlays/cpu
kubectl kustomize manifests/overlays/gpu
```

To exercise the workload, use a throwaway cluster (for example a dedicated kind
cluster) and run `scripts/check-prerequisites.sh` then `scripts/smoke-test.sh`
with `KUBE_CONTEXT` or `LAB_KUBECONFIG` pointing at it. Scripts refuse to guess a
target, so they will not touch whichever context happens to be current.

Include in your pull request what you ran and what happened.

## Cost and safety when running the lab

The optional `infra/` lab creates **billable** Linode resources, and a GPU
session is billed per hour until the instance is deleted. Use an account where
you are comfortable with that, preferably one that holds nothing else, because
the reaper token can delete any instance in its account. Do not run the lab
against resources you do not own. Always tear down and run `verify` when you are
done.

## Commits and pull requests

- Fork the repo and open a pull request against `main`.
- Use conventional commits: `type(scope): summary` in the imperative mood, summary
  under 72 characters, with a body that explains *why* rather than *what*.
- Keep a pull request to one logical change, and link the issue it addresses.

## Reporting problems

Open an issue with what you ran, what you expected, and what happened. Please do
not paste tokens, kubeconfigs or other credentials. For a security problem, do
not post details publicly; use GitHub's private vulnerability reporting for this
repository if it is enabled, or contact the maintainer directly.

## License

A license has not been chosen yet (see [LICENSE](LICENSE)). Contributions will be
under the license the project adopts.
