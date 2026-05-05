# savant-dataplane

Savant dataplane for self-managed Kubernetes deployments.

> ⚠️ **Scaffolding only.** This chart currently renders a single ConfigMap — dataplane workloads are not yet templated.

## Install

See [AWS Self-Managed Deployment](https://github.com/savantlabs/savant-terraform/blob/main/docs/aws_self-managed-deployment.md) for the full install guide, including infrastructure prerequisites.

Minimum install:

```bash
helm repo add savant https://savantlabs.github.io/helm-charts
helm install savant-dataplane savant/savant-dataplane \
  --namespace savant --create-namespace \
  -f my-values.yaml
```

## Values

| Key | Description |
|---|---|
| `savantConfig.agentId` | Savant agent ID from the Savant web app |
| `savantConfig.bucketName` | S3 bucket the agent uses |
