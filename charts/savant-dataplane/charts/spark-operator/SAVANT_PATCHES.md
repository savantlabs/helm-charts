# Savant patches to the Kubeflow Spark Operator chart

**Upstream:** `https://kubeflow.github.io/spark-operator` chart `spark-operator:2.5.0`

This directory is a snapshot of the upstream chart with a small number of
Savant-specific patches. Keep the list below in sync with the actual diffs so
future upstream merges are straightforward.

## Patches

1. Watch the release namespace by default
   - `templates/spark/_helpers.tpl`: new helper `spark-operator.spark.jobNamespaces`
     returns `spark.jobNamespaces` as JSON, substituting `[.Release.Namespace]`
     when the list is empty or unset.
   - Every `.Values.spark.jobNamespaces` reference under `templates/controller/`,
     `templates/webhook/` and `templates/spark/` now reads
     `(include "spark-operator.spark.jobNamespaces" $ | fromJsonArray)`.
   - `values.yaml`: `spark.jobNamespaces` default `[default]` → `[]`.
   - Reason: values files cannot reference `.Release.Namespace`, and upstream
     treats an empty list as watch-all. With this patch, a plain `helm install`
     scopes the controller (`--namespaces=<release ns>`) and gets a namespaced
     Role/RoleBinding, with no extra `--set` needed. `[""]` still means
     all namespaces.
   - Not changed: the controller ClusterRole/ClusterRoleBinding is still
     rendered, but in scoped mode it only grants `nodes get` and
     `customresourcedefinitions get`.

## Upstream sync

When bumping the vendored version:

1. `helm pull spark-operator --repo https://kubeflow.github.io/spark-operator --version <new> --untar -d /tmp/`
2. Copy the new tree over this directory.
3. Re-apply the patches above (`grep -rn '\.Values\.spark\.jobNamespaces' templates` should only match the helper).
4. Diff against previous snapshot to catch unintended upstream changes.
