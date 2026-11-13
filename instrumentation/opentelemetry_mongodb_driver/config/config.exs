import Config

if config_env() == :test do
  config :opentelemetry,
    processors: [{:otel_simple_processor, %{}}]

  config :opentelemetry_experimental,
    readers: [
      %{
        module: :otel_metric_reader,
        config: %{
          exporter: {:otel_metric_exporter_pid, {:otel_metric, :otel_mongodb_metric_test}}
        }
      }
    ]

  config :opentelemetry_mongodb_driver,
    url:
      System.get_env("MONGODB_URL", "mongodb://localhost:27017/opentelemetry_mongodb_driver_test")
end
