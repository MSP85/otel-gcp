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
    extensions:
      googleclientauth:
      health_check:
        endpoint: "0.0.0.0:{{ .Values.health.port }}"
        path: "{{ .Values.health.basePath }}"
    processors:
      # --- Memory limiter (always first)
      memory_limiter:
        check_interval: 10s
        limit_percentage: 40
        spike_limit_percentage: 10
      # --- Add k8s env metadata
      resource/traces_service_provider_k8s_environment:
        attributes:
          {{- range $key, $value := .Values.application.attribute }}
          - key: {{ snakecase $key | replace "_" "." | replace "service.provider" "service_provider" }}
            action: insert
            value: {{- tpl (toYaml $value) $ | indent 1 }}
          {{- end }}
      # --- Optional: span filters (existing logic)
      {{- range $key, $value := .Values.application.filter.rule }}
      filter/spans_wout_{{ snakecase $key }}:
        error_mode: ignore
        traces:
          span:
            - 'resource.attributes["{{ snakecase $key | replace "_" "." }}"] == nil'
            - 'IsMatch(resource.attributes["{{ snakecase $key | replace "_" "." }}"], "{{$value}}") == false'
          spanevent:
            - 'resource.attributes["{{ snakecase $key | replace "_" "." }}"] == nil'
            - 'IsMatch(resource.attributes["{{ snakecase $key | replace "_" "." }}"], "{{$value}}") == false'
      {{- end }}
      # --- Conditional CSI allowlist filter
      {{- if .Values.application.csiAllowlist }}
      filter/allow_csi:
        error_mode: ignore
        traces:
          include:
            match_type: strict
            attributes:
              - key: csi_id
                value:
                  {{- toYaml .Values.application.csiAllowlist | nindent 18 }}
      {{- end }}
      # --- Batch processor
      batch:
        send_batch_max_size: 0
        send_batch_size: 8192
        timeout: 200ms
    exporters:
      # --- Debug exporter (only enabled when configured in values)
      {{- if .Values.exporters.debug.enabled }}
      debug:
        sampling_initial: {{ .Values.exporters.debug.sampling_initial }}
        sampling_thereafter: {{ .Values.exporters.debug.sampling_thereafter }}
        verbosity: {{ .Values.exporters.debug.verbosity }}
      {{- end }}
      # --- GCP OTLP exporter
      otlphttp/gcp-cloud-isrp:
        auth:
          authenticator: googleclientauth
        encoding: proto
        endpoint: https://telemetry.googleapis.com
        tls:
          cipher_suite:
            {{- range $value := .Values.application.tls.cipherSuite }}
            - "{{$value}}"
            {{- end }}
          insecure: false
          insecure_skip_verify: false
          min_version: "1.2"
    service:
      telemetry:
        logs:
          encoding: console
          error_output_paths: ["stdout"]
          level: {{ .Values.telemetry.logs.level | quote }}
          output_paths: ["stdout"]
          sampling:
            enabled: false
        metrics:
          level: detailed
      extensions: [health_check, googleclientauth]
      pipelines:
        traces:
          receivers: [otlp]
          processors:
            - memory_limiter
            {{- range $value := .Values.application.filter.order }}
            - filter/spans_wout_{{ snakecase $value }}
            {{- end }}
            - resource/traces_service_provider_k8s_environment
            {{- if .Values.application.csiAllowlist }}
            - filter/allow_csi
            {{- end }}
            - batch
          exporters:
            - otlphttp/gcp-cloud-isrp
            {{- if .Values.exporters.debug.enabled }}
            - debug
            {{- end }}
