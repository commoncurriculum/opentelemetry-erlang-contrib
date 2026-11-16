import Config

if config_env() == :test do
  config :opentelemetry,
    processors: [{:otel_simple_processor, %{}}]

  config :opentelemetry_experimental,
    readers: [
      %{
        module: :otel_metric_reader,
        config: %{
          exporter: {:otel_metric_exporter_pid, {:otel_metric, :otel_ch_metric_test}}
        }
      }
    ]

  config :opentelemetry_ch,
    hostname: System.get_env("CLICKHOUSE_HOSTNAME", "localhost"),
    port: String.to_integer(System.get_env("CLICKHOUSE_PORT", "8123"))
end
