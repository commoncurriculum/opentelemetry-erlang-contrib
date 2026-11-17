defmodule OpentelemetryDBConnection.MixProject do
  use Mix.Project

  @version "0.1.0"
  @description "Record DBConnection pool wait and use time with OpenTelemetry."
  @repo_url "https://github.com/open-telemetry/opentelemetry-erlang-contrib"
  @folder_url "https://github.com/open-telemetry/opentelemetry-erlang-contrib/tree/main/instrumentation/opentelemetry_db_connection"

  def project do
    [
      app: :opentelemetry_db_connection,
      description: @description,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      source_url: @folder_url,
      docs: [
        source_url_pattern: "#{@folder_url}/%{path}#L%{line}",
        main: "OpentelemetryDBConnection",
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
      {:db_connection,
       github: "commoncurriculum/db_connection",
       ref: "e51ee86c5b291f6b517e167ce57b4449927a7231",
       override: true},
      {:ch,
       github: "commoncurriculum/ch",
       ref: "a78b1e29783a7c8386994113f5864f87a5ad4fc9",
       only: [:dev, :test]},
      {:postgrex, "~> 0.21", only: [:dev, :test]},
      {:opentelemetry, "== 1.7.0", only: [:dev, :test]},
      {:opentelemetry_exporter, "== 1.11.0", only: [:dev, :test]},
      {:opentelemetry_experimental, "== 0.6.0", only: [:dev, :test]},
      {:opentelemetry_api_experimental, "~> 0.6"},
      {:opentelemetry_semantic_conventions, "~> 1.27"},
      {:telemetry, "~> 0.4 or ~> 1.0"}
    ]
  end
end
