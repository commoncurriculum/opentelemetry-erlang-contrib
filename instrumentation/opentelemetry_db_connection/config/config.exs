import Config

if config_env() == :test do
  config :opentelemetry_experimental,
    readers: [
      %{
        module: :otel_metric_reader,
        config: %{
          exporter: {:otel_metric_exporter_pid, {:otel_metric, :otel_db_connection_metric_test}}
        }
      }
    ]

  config :opentelemetry_db_connection,
    clickhouse_hostname: System.get_env("CLICKHOUSE_HOSTNAME", "localhost"),
    clickhouse_port: String.to_integer(System.get_env("CLICKHOUSE_PORT", "8123")),
    postgres_hostname: System.get_env("POSTGRES_HOSTNAME", "localhost")
end
