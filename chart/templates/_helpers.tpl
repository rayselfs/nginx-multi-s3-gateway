{{/*
Expand the name of the chart.
*/}}
{{- define "nginx-multi-s3-gateway.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "nginx-multi-s3-gateway.fullname" -}}
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

{{/*
Create chart label.
*/}}
{{- define "nginx-multi-s3-gateway.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "nginx-multi-s3-gateway.labels" -}}
helm.sh/chart: {{ include "nginx-multi-s3-gateway.chart" . }}
{{ include "nginx-multi-s3-gateway.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "nginx-multi-s3-gateway.selectorLabels" -}}
app.kubernetes.io/name: {{ include "nginx-multi-s3-gateway.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
ServiceAccount name
*/}}
{{- define "nginx-multi-s3-gateway.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "nginx-multi-s3-gateway.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Compute S3_HOST_HEADER for the default bucket.
Mirrors the upstream entrypoint logic:
  virtual    → <bucketName>.<server>
  virtual-v2 → <bucketName>.<server>:<port>
  path       → <server>:<port>
*/}}
{{- define "nginx-multi-s3-gateway.s3HostHeader" -}}
{{- if eq .Values.s3.style "virtual" -}}
{{- printf "%s.%s" .Values.s3.bucketName .Values.s3.server -}}
{{- else if eq .Values.s3.style "virtual-v2" -}}
{{- printf "%s.%s:%v" .Values.s3.bucketName .Values.s3.server .Values.s3.serverPort -}}
{{- else -}}
{{- printf "%s:%v" .Values.s3.server .Values.s3.serverPort -}}
{{- end }}
{{- end }}

{{/*
Compute per-bucket S3 host.
Args: dict "bucket" <bucket object> "root" <root context ($)>
  virtual    → <bucket.name>.<server>
  virtual-v2 → <bucket.name>.<server>:<port>
  path       → <server>:<port>  (same endpoint regardless of bucket)
*/}}
{{- define "nginx-multi-s3-gateway.bucketS3Host" -}}
{{- $b := .bucket -}}
{{- $root := .root -}}
{{- if eq $root.Values.s3.style "virtual" -}}
{{- printf "%s.%s" $b.name $root.Values.s3.server -}}
{{- else if eq $root.Values.s3.style "virtual-v2" -}}
{{- printf "%s.%s:%v" $b.name $root.Values.s3.server $root.Values.s3.serverPort -}}
{{- else -}}
{{- printf "%s:%v" $root.Values.s3.server $root.Values.s3.serverPort -}}
{{- end }}
{{- end }}
