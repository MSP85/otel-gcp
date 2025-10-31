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
              ca_file: {{ .Values.application.tls.caFile }}
              cert_file: {{ .Values.application.tls.certFile }}
              cipher_suites:
                {{- range $value := .Values.application.tls.cipherSuite }}
                - "{{$value}}"
                {{- end }}
              key_file: {{ .Values.application.tls.keyFile }}
              min_version: "{{ .Values.application.tls.versionMinimum }}"

    extensions:
      googleclientauth: {}
      health_check:
        endpoint: "0.0.0.0:{{ .Values.health.port }}"
        path: "{{ .Values.health.basePath }}"

    processors:
      # === Memory limiter: first processor ===
      memory_limiter:
        check_interval: 10s
        limit_percentage: 40
        spike_limit_percentage: 10

      # === Allowlist CSI filter: drops traces if CSI ID not in allowed list ===
      csi_allowlist_filter:
        error_mode: ignore
        traces:
          span:
            - 'IsMatch(resource.attributes["citiClientCsiId"], "({{ join "|" .Values.application.csiAllowlist }})") == false'

      # === (Optional) existing filters — currently disabled for general use ===
      {{- range $key, $value := .Values.application.filter.rule }}
      filter/spans_wout_{{ snakecase $key | replace "_+_" "_" }}:
        error_mode: ignore
        traces:
          span:
            - 'resource.attributes["{{ snakecase $key | replace "_" "." | replace ".+." "_" }}"] == nil'
            - 'IsMatch(resource.attributes["{{ snakecase $key | replace "_" "." | replace ".+." "_" }}"], "{{$value}}") == false'
          spanevent:
            - 'resource.attributes["{{ snakecase $key | replace "_" "." | replace ".+." "_" }}"] == nil'
            - 'IsMatch(resource.attributes["{{ snakecase $key | replace "_" "." | replace ".+." "_" }}"], "{{$value}}") == false'
      {{- end }}

      # === Add environment attributes ===
      resource/traces_service_provider_k8s_environment:
        attributes:
          {{- range $key, $value := .Values.application.attribute }}
          - key: {{ snakecase $key | replace "_" "." | replace "service.provider" "service_provider" }}
            action: insert
            value: {{- tpl (toYaml $value) $ | indent 1 }}
          {{- end }}

      # === Batch processor ===
      batch:
        send_batch_max_size: 0
        send_batch_size: 8192
        timeout: 200ms

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
          min_version: "{{ .Values.application.tls.versionMinimum }}"

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
            - csi_allowlist_filter
            {{- range $value := .Values.application.filter.order }}
            - filter/spans_wout_{{ snakecase $value }}
            {{- end }}
            - resource/traces_service_provider_k8s_environment
            - batch
          exporters:
            - otlphttp/gcp-cloud
            {{- if .Values.application.exporter.debug.enabled }}
            - debug
            {{- end }}
