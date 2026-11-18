import Config

config :opentelemetry,
  processors: [{:otel_simple_processor, %{}}]

config :opentelemetry_experimental,
  readers: [
    %{
      module: :otel_metric_reader,
      config: %{
        exporter: {:otel_metric_exporter_pid, :opentelemetry_phoenix_metrics},
        default_temporality_mapping: %{histogram: :temporality_cumulative}
      }
    }
  ]
