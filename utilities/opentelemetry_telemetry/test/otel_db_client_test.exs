defmodule OtelDbClientTest do
  use ExUnit.Case

  import ExUnit.CaptureLog
  require Record

  for {name, spec} <- Record.extract_all(from_lib: "opentelemetry/include/otel_span.hrl") do
    Record.defrecord(name, spec)
  end

  @events [[:otel_db_client_test, :start], [:otel_db_client_test, :stop]]

  def handle([:otel_db_client_test, :start], _measurements, metadata, _config) do
    :otel_db_client.start(__MODULE__, metadata.ref, "SELECT users", %{"db.system.name": :test}, %{
      "db.query.text": "SELECT ?"
    })
  end

  def handle([:otel_db_client_test, :stop], %{duration: duration}, metadata, _config) do
    :otel_db_client.stop(metadata.ref, duration, metadata.finish)
  end

  setup do
    :otel_simple_processor.set_exporter(:otel_exporter_pid, self())
    :ok = :otel_db_client.attach(__MODULE__, @events, nil)
    on_exit(fn -> :telemetry.detach(__MODULE__) end)
    :ok
  end

  test "a query is a client span with its attributes, failed by its error type" do
    ref = make_ref()
    :telemetry.execute([:otel_db_client_test, :start], %{}, %{ref: ref})

    :telemetry.execute([:otel_db_client_test, :stop], %{duration: 1_000}, %{
      ref: ref,
      finish: fn _span -> {%{"db.response.returned_rows": 2}, %{"error.type": "42P01"}} end
    })

    assert_receive {:span,
                    span(
                      name: "SELECT users",
                      kind: :client,
                      attributes: attributes,
                      status: status
                    )}

    assert %{
             "db.system.name": :test,
             "db.query.text": "SELECT ?",
             "db.response.returned_rows": 2,
             "error.type": "42P01"
           } = :otel_attributes.map(attributes)

    assert status == {:status, :error, "42P01"}
  end

  test "a span ends even when finishing it raises, and the handler stays attached" do
    ref = make_ref()
    :telemetry.execute([:otel_db_client_test, :start], %{}, %{ref: ref})

    log =
      capture_log(fn ->
        :telemetry.execute([:otel_db_client_test, :stop], %{duration: 1_000}, %{
          ref: ref,
          finish: fn _span -> raise "boom" end
        })
      end)

    assert log =~ "boom"
    assert_receive {:span, span(name: "SELECT users")}
    assert Enum.any?(:telemetry.list_handlers([:otel_db_client_test]), &(&1.id == __MODULE__))
  end
end
