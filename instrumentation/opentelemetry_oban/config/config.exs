import Config

if config_env() == :test do
  config :opentelemetry_oban,
    ecto_repos: [TestRepo]

  config :opentelemetry_oban, TestRepo,
    hostname: "localhost",
    username: "postgres",
    password: "postgres",
    database: "opentelemetry_oban_test",
    pool: Ecto.Adapters.SQL.Sandbox

  config :opentelemetry_experimental,
    readers: [
      %{
        module: :otel_metric_reader,
        config: %{
          exporter: {:otel_metric_exporter_pid, :opentelemetry_oban_metrics},
          default_temporality_mapping: %{histogram: :temporality_cumulative}
        }
      }
    ]
end
