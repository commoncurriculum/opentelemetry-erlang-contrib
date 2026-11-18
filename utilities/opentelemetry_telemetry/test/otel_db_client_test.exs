defmodule OtelDbClientTest do
  use ExUnit.Case

  import ExUnit.CaptureLog
  require Record

  for {name, spec} <- Record.extract_all(from_lib: "opentelemetry/include/otel_span.hrl") do
    Record.defrecord(name, spec)
  end

  @events [[:otel_db_client_test, :start], [:otel_db_client_test, :stop]]

  def handle([:otel_db_client_test, :start], _measurements, metadata, _config) do
    :otel_db_client.start(
      __MODULE__,
      metadata.ref,
      %{"db.system.name": :test, "db.query.summary": "SELECT users"},
      %{"db.query.text": "SELECT ?"}
    )
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
      finish: fn _span -> {%{"error.type": "42P01"}, %{"db.response.returned_rows": 2}} end
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

  test "attributes known at the stop rename the span and go on it" do
    ref = make_ref()

    :otel_db_client.start(
      __MODULE__,
      ref,
      %{"db.system.name": :test, "db.operation.name": "ping"},
      %{}
    )

    :otel_db_client.stop(ref, 1_000, fn _span -> {%{"db.namespace": "app"}, %{}} end)

    assert_receive {:span, span(name: "PING app", attributes: attributes)}
    assert %{"db.namespace": "app"} = :otel_attributes.map(attributes)
  end

  test "a span is named after its summary, else its operation and target, else its system" do
    assert :otel_db_client.span_name(%{
             "db.system.name": :test,
             "db.query.summary": "SELECT users",
             "db.operation.name": "find"
           }) == "SELECT users"

    for {attributes, name} <- [
          {%{"db.operation.name": "find", "db.collection.name": "users", "db.namespace": "app"},
           "FIND users"},
          {%{"db.operation.name": "findAndModify", "db.collection.name": "users"},
           "FIND_AND_MODIFY users"},
          {%{"db.operation.name": "CREATE TABLE", "db.collection.name": "users"},
           "CREATE_TABLE users"},
          {%{"db.operation.name": "ping", "db.namespace": "app"}, "PING app"},
          {%{"db.operation.name": "ping", "server.address": "db", "server.port": 1}, "PING db:1"},
          {%{"db.operation.name": "ping"}, "PING"},
          {%{"db.namespace": "app"}, "app"},
          {%{}, "test"}
        ] do
      assert :otel_db_client.span_name(Map.put(attributes, :"db.system.name", :test)) == name
    end
  end

  test "a driver's command atom is the operation name as the database writes it" do
    assert :otel_db_client.operation_name(:insert) == "INSERT"
    assert :otel_db_client.operation_name(:create_table) == "CREATE TABLE"
    assert :otel_db_client.operation_name(nil) == :undefined
  end
end
