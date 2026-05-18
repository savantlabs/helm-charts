{{- define "savant-dataplane.labels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version | replace "+" "_" }}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{/*
WIF audience for the GCP projected-token volume. Parses the audience field
out of savantConfig.controlPlane.credentialConfig so customers don't have
to duplicate it. Returns empty string when credentialConfig is not set
(e.g. when existingCredentialConfigMap is used instead — in that case the
audience must be declared separately via savantConfig.controlPlane.wifAudience).
*/}}
{{- define "savant-dataplane.wifAudience" -}}
{{- $audience := .Values.savantConfig.controlPlane.wifAudience | default "" -}}
{{- if and (eq $audience "") .Values.savantConfig.controlPlane.credentialConfig -}}
  {{- $audience = (.Values.savantConfig.controlPlane.credentialConfig | fromJson).audience -}}
{{- end -}}
{{- $audience -}}
{{- end -}}

{{/*
Render `replicas: N` only on first install (resource doesn't yet exist) or
when the caller opts back in via `force=true`. On a normal `helm upgrade`
the field is omitted so the live value — set by the Savant agent's k8s
client or `kubectl scale` — is preserved across upgrades.

Args (dict): ctx, kind, name, replicas, force
*/}}
{{- define "savant-dataplane.replicas" -}}
{{- $existing := lookup "apps/v1" .kind .ctx.Release.Namespace .name -}}
{{- if or (not $existing) .force -}}
replicas: {{ .replicas }}
{{- end -}}
{{- end -}}
