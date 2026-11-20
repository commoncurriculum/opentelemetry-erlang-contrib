defmodule OpentelemetryCh.MixProject do
  use Mix.Project

  @version "0.1.0"
  @description "Trace ClickHouse queries made with the ch driver with OpenTelemetry."
  @repo_url "https://github.com/open-telemetry/opentelemetry-erlang-contrib"
  @folder_url "https://github.com/open-telemetry/opentelemetry-erlang-contrib/tree/main/instrumentation/opentelemetry_ch"

  def project do
    [
      app: :opentelemetry_ch,
      description: @description,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      source_url: @folder_url,
      docs: [
        source_url_pattern: "#{@folder_url}/%{path}#L%{line}",
        main: "OpentelemetryCh",
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
      {:ch,
       github: "commoncurriculum/ch",
       ref: "d709d0dcee94165d4a8ea3fcaaea1b983fd0e018",
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
       ref: "b09cdb1121a2dea11d6b1c6813a2ce9d72a757aa",
       sparse: "utilities/opentelemetry_telemetry"},
      {:opentelemetry_semantic_conventions, "~> 1.27"},
      {:telemetry, "~> 0.4 or ~> 1.0"}
    ]
  end
end
