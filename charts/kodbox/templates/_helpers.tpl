{{- define "kodbox.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "kodbox.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{- define "kodbox.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "kodbox.labels" -}}
helm.sh/chart: {{ include "kodbox.chart" . }}
app.kubernetes.io/name: {{ include "kodbox.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/* Selector labels for a component. Call with (dict "ctx" $ "component" "app") */}}
{{- define "kodbox.selectorLabels" -}}
app.kubernetes.io/name: {{ include "kodbox.name" .ctx }}
app.kubernetes.io/instance: {{ .ctx.Release.Name }}
app.kubernetes.io/component: {{ .component }}
{{- end }}

{{- define "kodbox.componentName" -}}
{{- printf "%s-%s" (include "kodbox.fullname" .ctx) .component | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "kodbox.dbSecretName" -}}
{{- default (printf "%s-db" (include "kodbox.fullname" .)) .Values.database.existingSecret }}
{{- end }}

{{- define "kodbox.adminSecretName" -}}
{{- default (printf "%s-admin" (include "kodbox.fullname" .)) .Values.admin.existingSecret }}
{{- end }}

{{- define "kodbox.dbHost" -}}
{{- if .Values.db.enabled }}
{{- include "kodbox.componentName" (dict "ctx" . "component" "db") }}
{{- else }}
{{- required "externalDatabase.host is required when db.enabled=false" .Values.externalDatabase.host }}
{{- end }}
{{- end }}

{{- define "kodbox.dbPort" -}}
{{- if .Values.db.enabled }}{{ .Values.db.service.port }}{{ else }}{{ .Values.externalDatabase.port }}{{ end }}
{{- end }}

{{- define "kodbox.redisHost" -}}
{{- if .Values.redis.enabled }}
{{- include "kodbox.componentName" (dict "ctx" . "component" "redis") }}
{{- else }}
{{- .Values.externalRedis.host }}
{{- end }}
{{- end }}

{{- define "kodbox.redisPort" -}}
{{- if .Values.redis.enabled }}{{ .Values.redis.service.port }}{{ else }}6379{{ end }}
{{- end }}

{{/*
Image reference. Call with (dict "ctx" $ "image" .Values.<component>.image),
plus "defaultTag" for an image whose empty tag falls back to it.
global.imageRegistry overrides image.registry. A repository that already
starts with a registry host (e.g. "quay.io/org/img") is used as-is.
*/}}
{{- define "kodbox.image" -}}
{{- $img := .image }}
{{- $repo := $img.repository }}
{{- $parts := splitList "/" $repo }}
{{- $host := first $parts }}
{{- $hasHost := and (gt (len $parts) 1) (or (contains "." $host) (contains ":" $host) (eq $host "localhost")) }}
{{- if not $hasHost }}
{{- $registry := default $img.registry (.ctx.Values.global | default dict).imageRegistry }}
{{- with $registry }}{{ $repo = printf "%s/%s" (trimSuffix "/" .) $repo }}{{ end }}
{{- end }}
{{- $ref := $repo }}
{{- with (default .defaultTag $img.tag) }}{{ $ref = printf "%s:%s" $ref (toString .) }}{{ end }}
{{- with $img.digest }}{{ $ref = printf "%s@%s" $ref . }}{{ end }}
{{- $ref }}
{{- end }}

{{/* Pod template labels. Call with (dict "ctx" $ "component" "app" "v" .Values.app) */}}
{{- define "kodbox.podLabels" -}}
{{ include "kodbox.selectorLabels" . }}
{{- with .v.podLabels }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{/*
Pod spec settings shared by every component: pull secrets, priority class and
scheduling. Call with (dict "ctx" $ "component" "app" "v" .Values.app), plus
"affinity" to replace v.affinity. Topology spread constraints without a
labelSelector get the component's selector labels.
*/}}
{{- define "kodbox.podScheduling" -}}
{{- with .ctx.Values.imagePullSecrets }}
imagePullSecrets:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with .v.priorityClassName }}
priorityClassName: {{ . }}
{{- end }}
{{- with .v.nodeSelector }}
nodeSelector:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with (hasKey . "affinity" | ternary .affinity .v.affinity) }}
affinity:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with .v.tolerations }}
tolerations:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- if .v.topologySpreadConstraints }}
{{- $selector := include "kodbox.selectorLabels" . | fromYaml }}
topologySpreadConstraints:
  {{- range .v.topologySpreadConstraints }}
  {{- $c := deepCopy . }}
  {{- if not $c.labelSelector }}
  {{- $_ := set $c "labelSelector" (dict "matchLabels" $selector) }}
  {{- end }}
  - {{ toYaml $c | indent 4 | trim }}
  {{- end }}
{{- end }}
{{- end }}

{{/* Fails the render on value combinations that deploy but can't work. */}}
{{- define "kodbox.validate" -}}
{{- $app := .Values.app }}
{{- $replicas := int $app.replicaCount }}
{{- if gt $replicas 1 }}
{{- if not $app.persistence.enabled }}
{{- fail "app.replicaCount > 1 needs app.persistence.enabled=true: replicas must share one volume" }}
{{- end }}
{{- if and (not $app.persistence.existingClaim) (not (has "ReadWriteMany" $app.persistence.accessModes)) }}
{{- fail "app.replicaCount > 1 needs a ReadWriteMany volume: set app.persistence.accessModes=[ReadWriteMany] with a storage class that supports it (see values-production.yaml)" }}
{{- end }}
{{- if not (include "kodbox.redisHost" .) }}
{{- fail "app.replicaCount > 1 needs redis for shared sessions: enable redis or set externalRedis.host" }}
{{- end }}
{{- if and $app.pdb.enabled (not (kindIs "string" $app.pdb.minAvailable)) (ge (int $app.pdb.minAvailable) $replicas) }}
{{- fail "app.pdb.minAvailable must be lower than app.replicaCount, or node drains are blocked" }}
{{- end }}
{{- end }}
{{- end }}
