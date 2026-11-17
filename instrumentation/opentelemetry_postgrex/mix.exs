defmodule OpentelemetryPostgrex.MixProject do
  use Mix.Project

  @version "0.1.0"
  @description "Trace PostgreSQL queries made with the Postgrex driver with OpenTelemetry."
  @repo_url "https://github.com/open-telemetry/opentelemetry-erlang-contrib"
  @folder_url "https://github.com/open-telemetry/opentelemetry-erlang-contrib/tree/main/instrumentation/opentelemetry_postgrex"

  def project do
    [
      app: :opentelemetry_postgrex,
      description: @description,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      source_url: @folder_url,
      docs: [
        source_url_pattern: "#{@folder_url}/%{path}#L%{line}",
        main: "OpentelemetryPostgrex",
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
      {:postgrex,
       github: "commoncurriculum/postgrex",
       ref: "7f82e20d03ff7e451bcd5dfe1b1b1030392e5142",
       only: [:dev, :test]},
      {:opentelemetry, "== 1.7.0", only: [:dev, :test]},
      {:opentelemetry_exporter, "== 1.11.0", only: [:dev, :test]},
      {:opentelemetry_experimental, "== 0.6.0", only: [:dev, :test]},
      {:nimble_options, "~> 1.0"},
      {:opentelemetry_api, "~> 1.4"},
      {:opentelemetry_api_experimental, "~> 0.6"},
      {:opentelemetry_process_propagator, "~> 0.3"},
      {:opentelemetry_telemetry,
       github: "commoncurriculum/opentelemetry-erlang-contrib",
       ref: "0181a1aafeb2a7ee5391aa4a9eecd21a1b191c3a",
       sparse: "utilities/opentelemetry_telemetry"},
      {:opentelemetry_semantic_conventions, "~> 1.27"},
      {:telemetry, "~> 0.4 or ~> 1.0"}
    ]
  end
end
