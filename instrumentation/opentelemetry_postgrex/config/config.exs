import Config

if config_env() == :test do
  config :opentelemetry,
    processors: [{:otel_simple_processor, %{}}]

  config :opentelemetry_experimental,
    readers: [
      %{
        module: :otel_metric_reader,
        config: %{
          exporter: {:otel_metric_exporter_pid, {:otel_metric, :otel_postgrex_metric_test}}
        }
      }
    ]

  config :opentelemetry_postgrex,
    hostname: System.get_env("POSTGRES_HOSTNAME", "localhost"),
    port: String.to_integer(System.get_env("POSTGRES_PORT", "5432"))
end
