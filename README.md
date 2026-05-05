# Savant Helm Charts

Helm charts published by Savant for customer installation.

## Charts

| Chart | Purpose |
|---|---|
| [`savant-dataplane`](charts/savant-dataplane) | Savant dataplane for self-managed Kubernetes deployments |

## Install

```bash
helm repo add savant https://savantlabs.github.io/helm-charts
helm repo update
helm install savant-dataplane savant/savant-dataplane -n savant --create-namespace -f my-values.yaml
```

See the chart's own README for the full install guide and values reference.

## Support

These charts are published for Savant customers. For product and deployment support, contact your Savant account team.

Security reports: see [`SECURITY.md`](SECURITY.md).
