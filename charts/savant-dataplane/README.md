# savant-dataplane

Helm chart that installs the Savant dataplane into a customer-managed Kubernetes cluster.

## What it installs

| Component | Kind | Purpose |
|---|---|---|
| `agent` | Deployment | Orchestrator that talks to Savant's control plane |
| `analytic-engine` | StatefulSet | Spark driver that submits jobs to the standalone cluster |
| `tei` | Deployment | Text embeddings inference server for Savant's GenAI features |
| `spark` (master + workers) | StatefulSets | Standalone Spark cluster for analytic workloads |
| `zookeeper` | StatefulSet | HA coordination for the Spark cluster |
| `spark-operator` | Deployment | Reconciles SparkApplication CRs submitted by the runtime |
| `savant-config` | ConfigMap | Non-sensitive agent config (agent ID, bucket, region, stack) |
| `savant-secrets` | Secret | Optional, holds the customer-generated STS External ID |
| `gcp-credential-config` | ConfigMap | Savant control-plane WIF credential-config (non-sensitive) |
| `savant-agent` | ServiceAccount + RoleBinding | Namespace-admin identity used by the agent and its workloads |

## Prerequisites

You will need:

- **Kubernetes 1.27+** on Amazon EKS with an OIDC provider (required for IRSA).
- **Three node groups**, each labeled with `pool.savant.io/type`:
  - `service` — long-running services (agent, operator, ZooKeeper, Spark master). 4 vCPU / 16 GiB, **minimum 3 nodes** (ZooKeeper and Spark master each run 3 replicas with hard per-host anti-affinity; spread across 3 AZs for quorum resilience).
  - `runtime` — memory-bound workloads (analytic-engine, TEI). 8 vCPU / 32 GiB family.
  - `spark` — Spark compute workers. 16 vCPU / 64 GiB family, typically Spot.
- **Cluster autoscaler** (or Karpenter) installed. Savant workloads are sized to drive node-level scale-out.
- **EBS CSI driver** installed so PVCs (ZK, TEI cache) can bind.
- **An IAM role (`savant-agent`)** whose trust policy lists the subject
  `system:serviceaccount:<release-namespace>:savant-agent`. This is what IRSA binds to the chart's ServiceAccount.
- **A WIF credential-config JSON** delivered by Savant. This authenticates customer pods to Savant's control-plane services without storing any long-lived secret in the cluster.

Your Savant account team provides the full deployment guide covering IAM policies, VPC requirements, and the onboarding values file for your agent.

## Install

Add the chart repository:

```bash
helm repo add savant https://savantlabs.github.io/helm-charts
helm repo update
```

Create a `my-values.yaml` with the values Savant provides in your onboarding file, plus anything your environment requires:

```yaml
savantConfig:
  agentId: "<your-agent-id>"
  cloudProvider: aws
  aws:
    region: us-west-2
    roleArn: arn:aws:iam::111122223333:role/savant-agent
    bucketName: savant-agent-<your-agent-id>
    externalId: "<customer-generated-external-id>"   # optional; see below
  controlPlane:
    credentialConfig: |
      {
        "type": "external_account",
        "audience": "...",
        "...": "..."
      }
```

Install:

```bash
helm install savant-dataplane savant/savant-dataplane \
  --namespace savant --create-namespace \
  -f my-values.yaml
```

The release name and namespace can be any values you prefer; the examples throughout this README assume `savant` for both. The namespace you install into must match the IRSA trust policy subject.

## Values reference

Only values you are expected to set or override are listed. Subchart values (ZooKeeper, Spark, Spark Operator) follow their upstream charts' contracts; see the linked documentation below.

### `savantConfig`

| Key | Default | Description |
|---|---|---|
| `agentId` | `""` | Your Savant agent ID. Required. |
| `cloudProvider` | `aws` | Customer cloud. Only `aws` is supported today. |
| `aws.region` | `""` | AWS region for SDK clients. Required when `cloudProvider=aws`. |
| `aws.roleArn` | `""` | IAM role ARN for IRSA. Required when `cloudProvider=aws`. |
| `aws.bucketName` | `""` | S3 bucket used for agent staging/artifact storage. Required when `cloudProvider=aws`. |
| `aws.externalId` | `""` | Optional customer-generated STS External ID. If set, rendered into the `savant-secrets` Secret and consumed by the analytic-engine for cross-account role assumption. |
| `controlPlane.credentialConfig` | `""` | GCP Workload Identity Federation credential-config JSON. Delivered by Savant; contains no long-lived secrets. |
| `controlPlane.existingCredentialConfigMap` | `""` | Alternative: reference a ConfigMap you manage yourself (External Secrets Operator, Vault CSI, etc.) containing `credential-config.json`. |
| `telemetry.otlpEndpoint` | `""` | Optional OTLP gRPC endpoint for trace export. Leave empty to disable, or point at your cluster's collector (for example `http://otel-collector.observability:4317`). |
| `telemetry.remoteWrite.enabled` | `true` | Deploys a [Grafana Alloy](https://grafana.com/docs/alloy/) pod that scrapes Savant Spring Boot pods and forwards the samples to Savant's hosted receiver so support can diagnose issues without remote shell access. Set to `false` to keep all telemetry inside your VPC — the dataplane functions identically, only Savant-side support visibility changes. |
| `telemetry.remoteWrite.endpoint` | `https://metrics.savantlabs.io/api/v1/push` | Prometheus remote_write receiver. The default is the Savant hosted receiver; Savant's `savant-onboarding.yaml` can override it for you. |

### `agent`, `analyticEngine`, `tei`

Each exposes the same shape. Override `image.tag` only if Savant support has directed you to a specific version; otherwise accept the chart defaults.

| Key | Description |
|---|---|
| `<component>.enabled` | Disable a component (not recommended except for testing). |
| `<component>.replicaCount` | Replica count. Defaults are `1` for every component. |
| `<component>.resources` | Standard Kubernetes resource requests/limits. Chart defaults are sized against the node-pool specs above. |
| `<component>.nodeSelector` | Defaults to the pool the component is intended for. |
| `<component>.image.tag` | Pinned; do not change unless directed. |

### TEI persistence

| Key | Default | Description |
|---|---|---|
| `tei.persistence.enabled` | `true` | Mount a PVC for the HuggingFace model cache so pod restarts don't re-download. |
| `tei.persistence.size` | `10Gi` | PVC size. |
| `tei.persistence.storageClass` | *(unset)* | Uses the cluster's default StorageClass. Override here or use `global.storageClass` to drive all subcharts at once. |

### Agent scratch storage

The agent stages source file downloads (e.g. multi-GB OneDrive or CSV files) on local scratch before processing. By default this is a dedicated per-pod volume, provisioned when the pod starts and deleted when it stops, so large files do not consume the node's ephemeral storage and cannot evict the pod. The volume is bound after the pod is scheduled, so it lands in the pod's availability zone and is never pinned across restarts.

| Key | Default | Description |
|---|---|---|
| `agent.persistence.enabled` | `true` | Provision a dedicated scratch volume per pod for staged file downloads. Set `false` to use an `emptyDir` on the node disk instead (requires a service node pool with enough disk for your largest source file). |
| `agent.persistence.size` | `100Gi` | Scratch volume size. Should comfortably exceed your largest single source file plus extraction overhead. |
| `agent.persistence.storageClass` | *(unset)* | Uses the cluster's default StorageClass. Override here or use `global.storageClass` to drive all subcharts at once. |

### Subchart passthrough

All top-level keys below are passed directly to the upstream subchart. Do not change them unless you have a specific reason.

- `zookeeper.*` — [Bitnami ZooKeeper](https://artifacthub.io/packages/helm/bitnami/zookeeper)
- `spark.*` — Bitnami Spark (vendored fork under `charts/spark/`; see `charts/spark/SAVANT_PATCHES.md`)
- `spark-operator.*` — [Kubeflow Spark Operator](https://artifacthub.io/packages/helm/spark-operator/spark-operator)
- `alloy.*` — [Grafana Alloy](https://artifacthub.io/packages/helm/grafana/alloy). Only deployed when `savantConfig.telemetry.remoteWrite.enabled=true`. The chart renders its config (ConfigMap `savant-metrics-forwarder-config`) and a namespace-scoped `Role` / `RoleBinding` itself, so the subchart's own ConfigMap and ClusterRole are disabled in the values.

#### Prometheus scrape annotations

Savant's Spring Boot pods (`agent`, `analytic-engine`) carry the standard Prometheus opt-in annotations:

```yaml
prometheus.io/scrape: "true"
prometheus.io/port: "8080"
prometheus.io/path: "/actuator/prometheus"
```

The in-chart Alloy forwarder discovers pods this way, and if you run your own Prometheus in the same cluster you can scrape them the same way — no extra chart flag needed.

## Upgrade

```bash
helm repo update
helm upgrade savant-dataplane savant/savant-dataplane \
  --namespace savant \
  -f my-values.yaml
```

The `savantConfig` values contract may evolve between `0.x.y` minor versions. Review the chart's release notes before upgrading across a minor bump.

Rollback a failed upgrade:

```bash
helm rollback savant-dataplane --namespace savant
```

## Uninstall

```bash
helm uninstall savant-dataplane --namespace savant
```

Helm will delete the release's resources but will **leave PersistentVolumeClaims** in place by default — this preserves ZooKeeper quorum data and the TEI model cache. Remove them explicitly if you want a clean wipe:

```bash
kubectl delete pvc --namespace savant -l app.kubernetes.io/instance=savant-dataplane
```

## Troubleshooting

**`WebIdentityErr: AccessDenied` in agent or analytic-engine logs.**
The IAM role's trust policy does not list the ServiceAccount subject this install uses. Verify the subject is `system:serviceaccount:<your-namespace>:savant-agent`, and that the OIDC provider ARN in the trust policy matches your cluster's OIDC issuer URL.

**ZooKeeper quorum never forms (pods restart in a loop).**
The three ZK pods are anti-affinity-spread across nodes. If your cluster has only one availability zone or if the service node group is too small, the scheduler cannot place all three. Scale the service node group up, or reduce `zookeeper.replicaCount` to `1` for a non-HA install.

**Spark master pod stuck `Pending`.**
Check `kubectl describe pod spark-master-0`. Common causes: service pool is full (add capacity), or a required volume's StorageClass isn't available (set `global.storageClass` or `spark.master.persistence.storageClass`).

**TEI pod stuck `Pending` with "Insufficient memory".**
TEI requests `12Gi` on the `runtime` pool. The runtime node group must have room; either add a node or shrink `tei.resources.requests.memory` to match your available capacity.

**Agent rolling-restart of analytic-engine fails.**
The agent expects the analytic-engine StatefulSet to be named exactly `analytic-engine`. The chart hardcodes that name; if you are overriding it, don't.

## Support

This chart is published for Savant customers. For product and deployment support, contact your Savant account team.

Security reports: see the repository's [SECURITY.md](https://github.com/savantlabs/helm-charts/blob/main/SECURITY.md).
