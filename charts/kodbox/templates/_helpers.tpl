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

{{- define "kodbox.image" -}}
{{- printf "%s:%s" .repository (toString .tag) }}
{{- end }}
