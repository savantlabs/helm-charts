# Savant Helm Charts

Helm charts published by Savant for customer installation.

## Charts

| Chart | Purpose |
|---|---|
| [`savant-dataplane`](charts/savant-dataplane) | Savant dataplane for self-managed Kubernetes deployments |

## Install

Charts are published to two locations. Either works; pick the one that fits your tooling.

**HTTP (classic Helm repository):**

```bash
helm repo add savant https://savantlabs.github.io/helm-charts
helm repo update
helm install savant-dataplane savant/savant-dataplane \
  -n savant --create-namespace -f my-values.yaml
```

**OCI (GitHub Container Registry):**

```bash
helm install savant-dataplane \
  oci://ghcr.io/savantlabs/charts/savant-dataplane \
  --version <chart-version> \
  -n savant --create-namespace -f my-values.yaml
```

List available versions before pinning:

```bash
helm search repo savant --versions              # HTTP
helm show chart oci://ghcr.io/savantlabs/charts/savant-dataplane --version <x.y.z>   # OCI
```

See the chart's own README for the full install guide and values reference.

## Upgrade

```bash
helm repo update
helm upgrade savant-dataplane savant/savant-dataplane \
  -n savant -f my-values.yaml
```

The customer-facing `values.yaml` is a versioned contract. Breaking changes land on a major version bump with migration notes in the GitHub release. Review the [release notes](https://github.com/savantlabs/helm-charts/releases) before upgrading across a minor bump while we are on `0.x`.

## Air-gapped and private registries

Customers running in restricted networks typically mirror chart images into a private registry. The chart supports this through standard Helm image overrides:

- `<component>.image.repository` on each Savant component (`agent`, `analyticEngine`, `tei`, `genai`)
- `global.imageRegistry` for the Bitnami-style subcharts (ZooKeeper, Spark)
- Subchart image overrides for Spark Operator per its [upstream values](https://github.com/kubeflow/spark-operator/tree/master/charts/spark-operator-chart)

Pull the chart locally with `helm pull oci://ghcr.io/savantlabs/charts/savant-dataplane --version <x.y.z>` to inspect images and relocate them with your tool of choice (`skopeo`, ORAS, Harbor replication, etc.). Your Savant account team can provide the authoritative image list for a given release.

## Support

| Channel | Use for |
|---|---|
| [GitHub Issues](https://github.com/savantlabs/helm-charts/issues) | Chart bugs, template errors, packaging issues |
| Savant account team | Product behavior, deployment planning, IAM/VPC setup, incident response |
| [`SECURITY.md`](SECURITY.md) | Security reports (do not file publicly) |
