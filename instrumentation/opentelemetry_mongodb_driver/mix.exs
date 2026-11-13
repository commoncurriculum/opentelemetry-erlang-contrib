defmodule OpentelemetryMongodbDriver.MixProject do
  use Mix.Project

  @version "0.2.0"
  @description "Trace MongoDB commands with OpenTelemetry."
  @repo_url "https://github.com/open-telemetry/opentelemetry-erlang-contrib"
  @folder_url "https://github.com/open-telemetry/opentelemetry-erlang-contrib/tree/main/instrumentation/opentelemetry_mongodb_driver"

  def project do
    [
      app: :opentelemetry_mongodb_driver,
      description: @description,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      source_url: @folder_url,
      docs: [
        source_url_pattern: "#{@folder_url}/%{path}#L%{line}",
        main: "OpentelemetryMongodbDriver",
        extras: ["README.md", "CHANGELOG.md"]
      ],
      package: [
        files: ~w(lib .formatter.exs mix.exs README* LICENSE* CHANGELOG*),
        licenses: ["Apache-2.0"],
        links: %{
          "GitHub" => @folder_url,
          "OpenTelemetry Erlang" => "https://github.com/open-telemetry/opentelemetry-erlang",
          "OpenTelemetry Erlang Contrib" => @repo_url,
          "OpenTelemetry.io" => "https://opentelemetry.io"
        }
      ]
    ]
  end

  def application do
    [
      extra_applications: []
    ]
  end

  defp deps do
    [
      {:ex_doc, "== 0.40.4", only: :dev, runtime: false},
      {:mongodb_driver,
       github: "commoncurriculum/elixir-mongodb-driver",
       ref: "05573b52df61f9958acc61e43962997dc0427126",
       only: [:dev, :test]},
      {:opentelemetry, "== 1.7.0", only: [:dev, :test]},
      {:opentelemetry_exporter, "== 1.11.0", only: [:dev, :test]},
      {:opentelemetry_experimental, "== 0.6.0", only: [:dev, :test]},
      {:jason, "~> 1.0"},
      {:nimble_options, "~> 1.0"},
      {:opentelemetry_api, "~> 1.4"},
      {:opentelemetry_api_experimental, "~> 0.6"},
      {:opentelemetry_process_propagator, "~> 0.3"},
      {:opentelemetry_semantic_conventions, "~> 1.27"},
      {:telemetry, "~> 0.4 or ~> 1.0"}
    ]
  end
end
