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

{{/* Namespace for every resource: namespaceOverride, else the release namespace. */}}
{{- define "kodbox.namespace" -}}
{{- default .Release.Namespace .Values.namespaceOverride | trunc 63 | trimSuffix "-" }}
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

{{- define "kodbox.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "kodbox.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/* Whether the document server uses JWT: explicit kodoffice.jwt.enabled, else on for onlyoffice. */}}
{{- define "kodbox.kodofficeJwt" -}}
{{- $jwt := .Values.kodoffice.jwt.enabled }}
{{- if kindIs "bool" $jwt }}{{ ternary "true" "" $jwt }}{{ else if eq .Values.kodoffice.edition "onlyoffice" }}true{{ end }}
{{- end }}

{{- define "kodbox.kodofficeJwtSecretName" -}}
{{- default (printf "%s-kodoffice" (include "kodbox.fullname" .)) .Values.kodoffice.jwt.existingSecret }}
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

{{/*
Environment list items added to every component's main container: TZ from
.Values.timezone, then v.extraEnv. Call with (dict "ctx" $ "v" .Values.<component>).
*/}}
{{- define "kodbox.extraEnv" -}}
{{- with .ctx.Values.timezone }}
- name: TZ
  value: {{ . | quote }}
{{- end }}
{{- with .v.extraEnv }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{/* Backup image: backup.image fields, falling back to db.image. */}}
{{- define "kodbox.backupImage" -}}
{{- $b := .Values.backup.image }}
{{- $d := .Values.db.image }}
{{- $img := dict "registry" (default $d.registry $b.registry) "repository" (default $d.repository $b.repository) "tag" (default $d.tag $b.tag) "digest" (default $d.digest $b.digest) }}
{{- include "kodbox.image" (dict "ctx" . "image" $img) }}
{{- end }}

{{/*
Container env and script for mariadb-dump, shared by the backup CronJob and its
helm test. DB credentials come from the database secret; MYSQL_PWD keeps the
password off the command line.
*/}}
{{- define "kodbox.backupEnv" -}}
- name: DB_HOST
  value: {{ include "kodbox.dbHost" . | quote }}
- name: DB_PORT
  value: {{ include "kodbox.dbPort" . | quote }}
- name: MYSQL_PWD
  valueFrom:
    secretKeyRef:
      name: {{ include "kodbox.dbSecretName" . }}
      key: MYSQL_PASSWORD
- name: KEEP
  value: {{ .Values.backup.keep | quote }}
{{- end }}

{{- define "kodbox.backupDumpCommand" -}}
mariadb-dump --host="$DB_HOST" --port="$DB_PORT" --user="$MYSQL_USER" --single-transaction --quick --routines --triggers {{- range .Values.backup.extraArgs }} {{ . | squote }}{{ end }} --databases "$MYSQL_DATABASE"
{{- end }}

{{/*
A container probe: the chart's default (YAML string, may be empty) with the
component's override merged over it, e.g. {periodSeconds: 30}. enabled: false
drops it; an override for a probe without a default needs its own handler.
Call with (dict "name" "livenessProbe" "default" `...` "override" .Values.x.livenessProbe).
*/}}
{{- define "kodbox.probe" -}}
{{- $override := .override | default dict }}
{{- $probe := mergeOverwrite (fromYaml .default | default dict) (omit $override "enabled") }}
{{- if and $probe (ne (toString (dig "enabled" true $override)) "false") }}
{{ .name }}:
  {{- toYaml $probe | nindent 2 }}
{{- end }}
{{- end }}

{{/* Pod template labels. Call with (dict "ctx" $ "component" "app" "v" .Values.app) */}}
{{- define "kodbox.podLabels" -}}
{{ include "kodbox.selectorLabels" . }}
{{- with .v.podLabels }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{/*
Pod spec settings shared by every component: service account, security
context, pull secrets, priority class and scheduling. Call with
(dict "ctx" $ "component" "app" "v" .Values.app), plus "affinity" to replace
v.affinity. Topology spread constraints without a labelSelector get the
component's selector labels.
*/}}
{{- define "kodbox.podScheduling" -}}
serviceAccountName: {{ include "kodbox.serviceAccountName" .ctx }}
automountServiceAccountToken: {{ .ctx.Values.serviceAccount.automountServiceAccountToken }}
{{- with .v.podSecurityContext }}
securityContext:
  {{- toYaml . | nindent 2 }}
{{- end }}
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
{{- $as := $app.autoscaling }}
{{- if and $as.enabled (lt (int $as.maxReplicas) (int $as.minReplicas)) }}
{{- fail "app.autoscaling.maxReplicas must be at least minReplicas" }}
{{- end }}
{{- if and $as.enabled (not $as.targetCPUUtilizationPercentage) (not $as.targetMemoryUtilizationPercentage) }}
{{- fail "app.autoscaling needs targetCPUUtilizationPercentage and/or targetMemoryUtilizationPercentage" }}
{{- end }}
{{- /* Checks below use the most replicas that can run, and the fewest that must. */}}
{{- $replicas := ternary (int $as.maxReplicas) (int $app.replicaCount) (and $as.enabled true) }}
{{- $minReplicas := ternary (int $as.minReplicas) (int $app.replicaCount) (and $as.enabled true) }}
{{- if gt $replicas 1 }}
{{- if not $app.persistence.enabled }}
{{- fail "more than one app replica (replicaCount or autoscaling) needs app.persistence.enabled=true: replicas must share one volume" }}
{{- end }}
{{- if and (not $app.persistence.existingClaim) (not (has "ReadWriteMany" $app.persistence.accessModes)) }}
{{- fail "more than one app replica (replicaCount or autoscaling) needs a ReadWriteMany volume: set app.persistence.accessModes=[ReadWriteMany] with a storage class that supports it (see values-production.yaml)" }}
{{- end }}
{{- if not (include "kodbox.redisHost" .) }}
{{- fail "more than one app replica (replicaCount or autoscaling) needs redis for shared sessions: enable redis or set externalRedis.host" }}
{{- end }}
{{- if and $app.pdb.enabled (gt $minReplicas 1) (not (kindIs "string" $app.pdb.minAvailable)) (ge (int $app.pdb.minAvailable) $minReplicas) }}
{{- fail "app.pdb.minAvailable must be lower than app.replicaCount (or autoscaling.minReplicas), or node drains are blocked" }}
{{- end }}
{{- end }}
{{- end }}
