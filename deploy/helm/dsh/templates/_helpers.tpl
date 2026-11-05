{{- define "dsh.fullname" -}}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "dsh.labels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end -}}

{{- define "dsh.selector" -}}
app.kubernetes.io/name: {{ .name }}
app.kubernetes.io/instance: {{ .root.Release.Name }}
{{- end -}}

{{- define "dsh.image" -}}
{{ .Values.image.repository }}:{{ .Values.image.tag | default .Chart.AppVersion }}
{{- end -}}

{{- define "dsh.secretName" -}}
{{- default (printf "%s-api" (include "dsh.fullname" .)) .Values.deepseek.existingSecret -}}
{{- end -}}

{{- define "dsh.env" -}}
- name: DEEPSEEK_API_KEY
  valueFrom:
    secretKeyRef:
      name: {{ include "dsh.secretName" . }}
      key: DEEPSEEK_API_KEY
{{- with .Values.deepseek.baseUrl }}
- name: DEEPSEEK_BASE_URL
  value: {{ . | quote }}
{{- end }}
{{- with .Values.env }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{- define "dsh.pvcName" -}}
{{- if .Values.pvc.create -}}
{{- default (printf "%s-home" (include "dsh.fullname" .)) .Values.pvc.name -}}
{{- else -}}
{{- required "pvc.name is required when pvc.create is false" .Values.pvc.name -}}
{{- end -}}
{{- end -}}

{{- define "dsh.sdkTokenSecret" -}}
{{- default (printf "%s-sdk-token" (include "dsh.fullname" .)) .Values.sdk.service.existingSecret -}}
{{- end -}}

{{- define "dsh.initContainers" -}}
{{- if .Values.pvc.subPath }}
initContainers:
  - name: init-storage
    image: {{ include "dsh.image" . }}
    imagePullPolicy: {{ .Values.image.pullPolicy }}
    command:
      - mkdir
      - -p
      - /vol/{{ .Values.pvc.subPath }}
      {{- if hasPrefix "/home/dsh/" (.Values.workingDir | default "/home/dsh") }}
      - /vol/{{ .Values.pvc.subPath }}/{{ trimPrefix "/home/dsh/" .Values.workingDir }}
      {{- end }}
    volumeMounts:
      - name: home
        mountPath: /vol
{{- end }}
{{- end -}}
