# Savant patches to the Bitnami Spark chart

**Upstream:** `oci://registry-1.docker.io/bitnamicharts/spark:10.0.3`

This directory is a snapshot of the upstream chart with a small number of
Savant-specific patches. Keep the list below in sync with the actual diffs so
future upstream merges are straightforward.

## Patches

1. `templates/statefulset-master.yaml`
   - `replicas: 1` → `replicas: {{ .Values.master.replicaCount | default 1 }}`
   - Reason: upstream hardcodes a single master. We run an HA master
     quorum (3) backed by ZooKeeper recovery.

2. `templates/statefulset-worker.yaml`
   - `SPARK_MASTER_URL` env is now gated behind `.Values.worker.skipDefaultMasterUrl`.
   - Reason: upstream always injects a single-master URL, which conflicts
     with our workers receiving the full 3-master quorum URL via
     `worker.extraEnvVars`. Kubernetes 1.28+ rejects duplicate env keys.

3. `templates/statefulset-worker.yaml`
   - `replicas: {{ .Values.worker.replicaCount }}` is now rendered only on
     first install (resource not yet present), via a `lookup` guard.
   - Reason: worker count is reconciled at runtime by the Savant agent
     (derived from analytic-engine count). Omitting `replicas` from the
     applied manifest on subsequent upgrades lets Kubernetes' 3-way merge
     leave the live value alone, so agent-driven scaling survives
     `helm upgrade`. Recovery path is `kubectl scale` if the agent's
     reconciliation is wedged.

## Upstream sync

When bumping the vendored version:

1. `helm pull oci://registry-1.docker.io/bitnamicharts/spark --version <new> --untar -d /tmp/`
2. Copy the new tree over this directory.
3. Re-apply the patches above.
4. Diff against previous snapshot to catch unintended upstream changes.
