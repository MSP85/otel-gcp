apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ .Values.serviceName }}-config
data:
  {{ .Values.serviceName }}-config.yaml: |
    receivers:
      otlp:
        protocols:
          http:
            endpoint: 0.0.0.0:{{ .Values.application.port.http }}
      prometheus/internal:
        config:
          scrape_configs:
            - job_name: 'otel-collector-internal'
              scrape_interval: 10s
              static_configs:
                - targets: ['0.0.0.0:8888']  # internal telemetry endpoint

    extensions:
      googleclientauth: {}
      health_check:
        endpoint: "0.0.0.0:{{ .Values.health.port }}"
        path: "{{ .Values.health.basePath }}"

    processors:
      batch:
        send_batch_max_size: 0
        send_batch_size: 8192
        timeout: 200ms

      {{- if .Values.application.csiAllowlist }}
      filter/spans_with_allowlist:
        error_mode: drop
        traces:
          span:
            - 'IsMatch(resource.attributes["client.csi.id"], "^( {{ join "|" .Values.application.csiAllowlist }} )$") == false'
          spanevent:
            - 'IsMatch(resource.attributes["client.csi.id"], "^( {{ join "|" .Values.application.csiAllowlist }} )$") == false'
      {{- end }}

      memory_limiter:
        check_interval: 10s
        limit_percentage: 40
        spike_limit_percentage: 10

      resource/traces_service_provider_k8s_environment:
        attributes:
          {{- range $key, $value := .Values.application.attribute }}
          - key: {{ snakecase $key | replace "_" "." | replace "service.provider" "service_provider" }}
            action: insert
            value: {{- tpl (toYaml $value) $ | indent 1 }}
          {{- end }}

      resource/internal_metrics_attributes:
        attributes:
          - key: client.csi.id
            action: insert
            value: {{ .Values.application.csiId }}
          - key: gcp.project.id
            action: insert
            value: {{ .Values.application.projectId }}

    exporters:
      otlphttp/gcp-cloud:
        auth:
          authenticator: googleclientauth
        encoding: proto
        endpoint: https://telemetry.googleapis.com

      otlphttp/metrics-gateway:
        endpoint: {{ .Values.application.metricsGateway.endpoint }}
        compression: gzip
        tls:
          insecure: false

      {{- if .Values.application.exporter.debug.enabled }}
      debug:
        sampling_initial: {{ .Values.application.exporter.debug.initialSampleCount }}
        sampling_thereafter: {{ .Values.application.exporter.debug.sampleFrequency }}
        verbosity: {{ .Values.application.exporter.debug.verbosity }}
      {{- end }}

    service:
      telemetry:
        logs:
          level: {{ .Values.logging.level | quote }}
          encoding: {{ .Values.logging.encoding | quote }}
          output_paths: {{ toYaml .Values.logging.outputPaths | nindent 10 }}
          error_output_paths: {{ toYaml .Values.logging.errorOutputPaths | nindent 10 }}
          sampling:
            enabled: {{ .Values.logging.sampling.enabled }}
            {{- if .Values.logging.sampling.enabled }}
            initial: {{ .Values.logging.sampling.initial }}
            thereafter: {{ .Values.logging.sampling.thereafter }}
            {{- end }}
        metrics:
          address: 0.0.0.0:8888
          level: detailed

      extensions: [health_check, googleclientauth]

      pipelines:
        traces:
          receivers: [otlp]
          processors:
            - memory_limiter
            {{- if .Values.application.csiAllowlist }}
            - filter/spans_with_allowlist
            {{- end }}
            - resource/traces_service_provider_k8s_environment
            - batch
          exporters:
            - otlphttp/gcp-cloud
            {{- if .Values.application.exporter.debug.enabled }}
            - debug
            {{- end }}


        metrics/internal:
          receivers: [prometheus/internal]
          processors: [resource/internal_metrics_attributes, batch]
          exporters: [otlphttp/metrics-gateway]




application:
  csiToProjectMap:
    "176443": "gcp-project-1"
    "180921": "gcp-project-2"
    "190122": "gcp-project-3"





{{- if .Values.application.csiToProjectMap }}
      filter/validate_csi_project_mapping:
        error_mode: drop
        traces:
          span:
          {{- range $csi, $project := .Values.application.csiToProjectMap }}
            - |
              (
                resource.attributes["client.csi.id"] == "{{ $csi }}" and
                resource.attributes["gcp.project.id"] != "{{ $project }}"
              )
          {{- end }}
          spanevent:
          {{- range $csi, $project := .Values.application.csiToProjectMap }}
            - |
              (
                resource.attributes["client.csi.id"] == "{{ $csi }}" and
                resource.attributes["gcp.project.id"] != "{{ $project }}"
              )
          {{- end }}
{{- end }}





processors:
  - memory_limiter
  {{- if .Values.application.csiToProjectMap }}
  - filter/validate_csi_project_mapping
  {{- end }}
  - resource/traces_service_provider_k8s_environment
  - batch









apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ .Values.serviceName }}-config
data:
  {{ .Values.serviceName }}-config.yaml: |
    receivers:
      otlp:
        protocols:
          http:
            endpoint: 0.0.0.0:{{ .Values.application.port.http }}
            tls:
              ca_file: {{.Values.application.tls.caFile}}
              cert_file: {{.Values.application.tls.certFile}}
              cipher_suites:
                {{- range $value := .Values.application.tls.cipherSuite }}
                - "{{$value}}"
                {{- end }}
              key_file: {{.Values.application.tls.keyFile}}
              min_version: "{{.Values.application.tls.versionMinimum}}"

    extensions:
      googleclientauth: {}
      health_check:
        endpoint: "0.0.0.0:{{ .Values.health.port }}"
        path: "{{ .Values.health.basePath }}"

    processors:
      batch:
        send_batch_max_size: 0
        send_batch_size: 8192
        timeout: 200ms

      memory_limiter:
        check_interval: 10s
        limit_percentage: 40
        spike_limit_percentage: 10

      {{- if .Values.application.csiToProjectMap }}
      filter/validate_csi_project_mapping:
        error_mode: drop
        traces:
          span:
          {{- range $csi, $project := .Values.application.csiToProjectMap }}
            - |
              (
                resource.attributes["client.csi.id"] == "{{ $csi }}" and
                resource.attributes["gcp.project.id"] != "{{ $project }}"
              )
          {{- end }}
          spanevent:
          {{- range $csi, $project := .Values.application.csiToProjectMap }}
            - |
              (
                resource.attributes["client.csi.id"] == "{{ $csi }}" and
                resource.attributes["gcp.project.id"] != "{{ $project }}"
              )
          {{- end }}
      {{- end }}

      resource/traces_service_provider_k8s_environment:
        attributes:
          {{- range $key, $value := .Values.application.attribute }}
          - key: {{ snakecase $key | replace "_" "." | replace "service.provider" "service_provider" }}
            action: insert
            value: {{- tpl (toYaml $value) $ | indent 1 }}
          {{- end }}

    exporters:
      {{- if .Values.application.exporter.debug.enabled }}
      debug:
        sampling_initial: {{ .Values.application.exporter.debug.initialSampleCount }}
        sampling_thereafter: {{ .Values.application.exporter.debug.sampleFrequency }}
        verbosity: {{ .Values.application.exporter.debug.verbosity }}
      {{- end }}
      otlphttp/gcp-cloud:
        auth:
          authenticator: googleclientauth
        encoding: proto
        endpoint: https://telemetry.googleapis.com
        tls:
          cipher_suites:
            {{- range $value := .Values.application.tls.cipherSuite }}
            - "{{$value}}"
            {{- end }}
          insecure: false
          insecure_skip_verify: false
          min_version: "{{.Values.application.tls.versionMinimum}}"

    service:
      telemetry:
        logs:
          level: {{ .Values.logging.level | quote }}
          encoding: {{ .Values.logging.encoding | quote }}
          output_paths: {{ toYaml .Values.logging.outputPaths | nindent 10 }}
          error_output_paths: {{ toYaml .Values.logging.errorOutputPaths | nindent 10 }}
          sampling:
            enabled: {{ .Values.logging.sampling.enabled }}
            {{- if .Values.logging.sampling.enabled }}
            initial: {{ .Values.logging.sampling.initial }}
            thereafter: {{ .Values.logging.sampling.thereafter }}
            {{- end }}
        metrics:
          level: detailed

      extensions: [health_check, googleclientauth]

      pipelines:
        traces:
          receivers: [otlp]
          processors:
            - memory_limiter
            {{- if .Values.application.csiToProjectMap }}
            - filter/validate_csi_project_mapping
            {{- end }}
            - resource/traces_service_provider_k8s_environment
            - batch
          exporters:
            - otlphttp/gcp-cloud
            {{- if .Values.application.exporter.debug.enabled }}
            - debug
            {{- end }}

