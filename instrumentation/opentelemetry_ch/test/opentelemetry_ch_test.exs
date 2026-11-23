defmodule OpentelemetryChTest do
  use ExUnit.Case

  require OpenTelemetry.Tracer, as: Tracer
  require Record

  for {name, spec} <- Record.extract_all(from_lib: "opentelemetry/include/otel_span.hrl") do
    Record.defrecord(name, spec)
  end

  for {name, spec} <-
        Record.extract_all(from_lib: "opentelemetry_experimental/include/otel_metrics.hrl") do
    Record.defrecord(name, spec)
  end

  @database "opentelemetry_ch_test"

  setup_all do
    hostname = Application.fetch_env!(:opentelemetry_ch, :hostname)
    port = Application.fetch_env!(:opentelemetry_ch, :port)

    {:ok, admin} = Ch.start_link(hostname: hostname, port: port)
    Ch.query!(admin, "CREATE DATABASE IF NOT EXISTS #{@database}")
    Ch.query!(admin, "CREATE OR REPLACE TABLE #{@database}.events (name String) ENGINE Memory")

    {:ok, conn} = Ch.start_link(hostname: hostname, port: port, database: @database)
    {:ok, conn: conn, hostname: hostname}
  end

  setup do
    :otel_simple_processor.set_exporter(:otel_exporter_pid, self())
    on_exit(fn -> :telemetry.detach(OpentelemetryCh) end)
    :ok
  end

  test "a query is a client span named after its summary, under the current span",
       %{conn: conn, hostname: hostname} do
    OpentelemetryCh.setup()

    Tracer.with_span "parent" do
      Ch.query!(conn, "SELECT {a:UInt8}", %{"a" => 1})
    end

    assert_receive {:span, span(name: "parent", span_id: parent_span_id)}

    assert_receive {:span,
                    span(
                      name: "SELECT",
                      kind: :client,
                      parent_span_id: ^parent_span_id,
                      start_time: start_time,
                      end_time: end_time,
                      attributes: attributes,
                      status: :undefined
                    )}

    assert start_time < end_time

    assert :otel_attributes.map(attributes) == %{
             "db.system.name": :clickhouse,
             "db.namespace": @database,
             "db.operation.name": "SELECT",
             "db.query.summary": "SELECT",
             "db.query.text": "SELECT {a:UInt8}",
             "db.response.returned_rows": 1,
             "server.address": hostname
           }
  end

  test "an insert reports no returned rows", %{conn: conn} do
    OpentelemetryCh.setup()

    Ch.query!(conn, "INSERT INTO events FORMAT RowBinary", [["Ada"]], types: ["String"])

    assert_receive {:span, span(name: "INSERT events", attributes: attributes)}
    refute Map.has_key?(:otel_attributes.map(attributes), :"db.response.returned_rows")
  end

  test "a query's source names the table", %{conn: conn} do
    OpentelemetryCh.setup()

    Ch.query!(conn, "SELECT name FROM events", [], source: "events")

    assert_receive {:span, span(name: "SELECT events", attributes: attributes)}
    assert %{"db.collection.name": "events"} = :otel_attributes.map(attributes)
  end

  test "an insert is named INSERT", %{conn: conn} do
    OpentelemetryCh.setup()

    Ch.query!(conn, "INSERT INTO events FORMAT RowBinary", [["Ada"]], types: ["String"])

    assert_receive {:span, span(name: "INSERT events")}
  end

  test "a streamed read is one span that ends after its last row", %{conn: conn} do
    OpentelemetryCh.setup()

    last_row_at =
      DBConnection.run(conn, fn conn ->
        conn
        |> Ch.stream("SELECT number FROM numbers(5) SETTINGS max_block_size = 1")
        |> Enum.reduce(nil, fn _result, _ -> :opentelemetry.timestamp() end)
      end)

    assert_receive {:span,
                    span(name: "SELECT numbers", end_time: end_time, attributes: attributes)}

    assert end_time > last_row_at
    assert %{"db.response.returned_rows": 5} = :otel_attributes.map(attributes)
    refute_receive {:span, span(name: "SELECT numbers")}
  end

  test "a streamed insert is one span named after its table", %{conn: conn} do
    OpentelemetryCh.setup()

    DBConnection.run(conn, fn conn ->
      stream =
        Ch.stream(conn, "INSERT INTO events FORMAT RowBinary", [],
          encode: false,
          source: "events"
        )

      [["Ada"], ["Grace"]]
      |> Stream.map(&Ch.RowBinary.encode_row(&1, ["String"]))
      |> Enum.into(stream)
    end)

    assert_receive {:span, span(name: "INSERT events", status: :undefined)}
    refute_receive {:span, span(name: "INSERT events")}
  end

  test "a query run in a task is a child of the span that started the task", %{conn: conn} do
    OpentelemetryCh.setup()

    Tracer.with_span "parent" do
      Task.await(Task.async(fn -> Ch.query!(conn, "SELECT 1") end))
    end

    assert_receive {:span, span(name: "parent", span_id: parent_span_id)}
    assert_receive {:span, span(name: "SELECT", parent_span_id: ^parent_span_id)}
  end

  test "a failed query fails its span with the ClickHouse error code", %{conn: conn} do
    OpentelemetryCh.setup()

    {:error, %Ch.Error{code: 60}} = Ch.query(conn, "SELECT * FROM missing")

    assert_receive {:span,
                    span(
                      name: "SELECT missing",
                      status: {:status, :error, "60"},
                      attributes: attributes
                    )}

    assert %{"error.type": "60", "db.response.status_code": "60"} =
             :otel_attributes.map(attributes)
  end

  test "a transport error fails its span with the error's module", %{conn: conn} do
    OpentelemetryCh.setup()

    {:error, %Mint.TransportError{}} = Ch.query(conn, "SELECT sleep(1)", [], timeout: 100)

    assert_receive {:span,
                    span(status: {:status, :error, "Mint.TransportError"}, attributes: attributes)}

    assert %{"error.type": "Mint.TransportError"} = :otel_attributes.map(attributes)
    refute Map.has_key?(:otel_attributes.map(attributes), :"db.response.status_code")
  end

  @tag :capture_log
  test "a query that raises fails its span and records the exception", %{conn: conn} do
    OpentelemetryCh.setup()
    rows = Stream.map([1], fn _ -> raise ArgumentError, "bad row" end)

    assert_raise ArgumentError, fn ->
      Ch.query(conn, "INSERT INTO events FORMAT RowBinary", rows, encode: false)
    end

    assert_receive {:span,
                    span(
                      name: "INSERT events",
                      status: {:status, :error, "ArgumentError"},
                      events: events
                    )}

    assert [event(name: :exception)] = :otel_events.list(events)
  end

  @tag :capture_log
  test "a stream whose checkout times out is ended by the pool with the timeout error", %{
    hostname: hostname
  } do
    OpentelemetryCh.setup()
    port = Application.fetch_env!(:opentelemetry_ch, :port)
    {:ok, conn} = Ch.start_link(hostname: hostname, port: port, database: @database, pool_size: 1)

    assert_raise DBConnection.ConnectionError, fn ->
      DBConnection.run(
        conn,
        fn conn ->
          conn
          |> Ch.stream("SELECT number FROM numbers(5000000) SETTINGS max_block_size=1000")
          |> Stream.each(fn _ -> Process.sleep(50) end)
          |> Stream.run()
        end,
        timeout: 300
      )
    end

    assert_receive {:span,
                    span(
                      name: "SELECT numbers",
                      status: {:status, :error, "DBConnection.ConnectionError"}
                    )},
                   1_000
  end

  @tag :capture_log
  test "a span whose caller is killed mid-query fails and ends as the caller dies", %{conn: conn} do
    OpentelemetryCh.setup()
    test = self()

    caller =
      spawn(fn ->
        send(test, :querying)
        Ch.query(conn, "SELECT sleep(2)")
      end)

    assert_receive :querying
    Process.sleep(100)
    Process.exit(caller, :kill)

    assert_receive {:span,
                    span(
                      name: "SELECT",
                      status: {:status, :error, "_OTHER"},
                      start_time: start_time,
                      end_time: end_time,
                      attributes: attributes
                    )},
                   500

    assert System.convert_time_unit(end_time - start_time, :native, :millisecond) < 1_000
    assert %{"error.type": "_OTHER"} = :otel_attributes.map(attributes)
  end

  test "db.query.text has every literal replaced by ? by default", %{conn: conn} do
    OpentelemetryCh.setup()

    Ch.query!(conn, "SELECT 'Ada', 42, {a:UInt8}", %{"a" => 1})

    assert_receive {:span, span(attributes: attributes)}
    assert %{"db.query.text": "SELECT ?, ?, {a:UInt8}"} = :otel_attributes.map(attributes)
  end

  test "db.query.text keeps every literal when plain", %{conn: conn} do
    OpentelemetryCh.setup(query_sanitization: false)

    Ch.query!(conn, "SELECT 'Ada', 42")

    assert_receive {:span, span(attributes: attributes)}
    assert %{"db.query.text": "SELECT 'Ada', 42"} = :otel_attributes.map(attributes)
  end

  test "db.query.text is left out when disabled", %{conn: conn} do
    OpentelemetryCh.setup(opt_out_attrs: [:"db.query.text"])

    Ch.query!(conn, "SELECT 1")

    assert_receive {:span, span(attributes: attributes)}
    refute Map.has_key?(:otel_attributes.map(attributes), :"db.query.text")
  end

  describe "db.client.operation.duration" do
    setup do
      Process.register(self(), :otel_ch_metric_test)
      :ok
    end

    test "is recorded for each query with the span's attributes", %{conn: conn} do
      OpentelemetryCh.setup()

      Ch.query!(conn, "SELECT name FROM events", [], source: "events")
      {:error, _} = Ch.query(conn, "SELECT * FROM missing")
      :otel_meter_server.force_flush()

      assert_receive {:otel_metric,
                      metric(
                        name: :"db.client.operation.duration",
                        unit: :s,
                        data: histogram(datapoints: datapoints)
                      )}

      assert histogram_datapoint(count: count, sum: sum) =
               Enum.find(
                 datapoints,
                 &match?(
                   histogram_datapoint(
                     attributes: %{
                       "db.system.name": :clickhouse,
                       "db.namespace": @database,
                       "db.operation.name": "SELECT",
                       "db.collection.name": "events",
                       "db.query.summary": "SELECT events"
                     }
                   ),
                   &1
                 )
               )

      assert count >= 1 and sum > 0

      assert Enum.any?(
               datapoints,
               &match?(
                 histogram_datapoint(
                   attributes: %{"error.type": "60", "db.response.status_code": "60"}
                 ),
                 &1
               )
             )

      refute Enum.any?(
               datapoints,
               &match?(histogram_datapoint(attributes: %{"db.query.text": _}), &1)
             )
    end
  end
end
