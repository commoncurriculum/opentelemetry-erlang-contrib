defmodule OpentelemetryPostgrexTest do
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

  @database "postgres"

  setup_all do
    hostname = Application.fetch_env!(:opentelemetry_postgrex, :hostname)
    port = Application.fetch_env!(:opentelemetry_postgrex, :port)

    {:ok, conn} =
      Postgrex.start_link(
        hostname: hostname,
        port: port,
        username: "postgres",
        password: "postgres",
        database: @database
      )

    Postgrex.query!(conn, "DROP TABLE IF EXISTS otel_events", [])
    Postgrex.query!(conn, "CREATE TABLE otel_events (name text)", [])
    {:ok, conn: conn, hostname: hostname}
  end

  setup do
    :otel_simple_processor.set_exporter(:otel_exporter_pid, self())
    on_exit(fn -> :telemetry.detach(OpentelemetryPostgrex) end)
    :ok
  end

  test "a query is a client span named after its summary, under the current span",
       %{conn: conn, hostname: hostname} do
    OpentelemetryPostgrex.setup()

    Tracer.with_span "parent" do
      Postgrex.query!(conn, "SELECT $1::int", [1])
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
             "db.system.name": :postgresql,
             "db.namespace": @database,
             "db.operation.name": "SELECT",
             "db.query.summary": "SELECT",
             "db.query.text": "SELECT $1::int",
             "db.response.returned_rows": 1,
             "server.address": hostname
           }
  end

  test "a query's source names the table", %{conn: conn} do
    OpentelemetryPostgrex.setup()

    Postgrex.query!(conn, "INSERT INTO otel_events VALUES ($1)", ["Ada"], source: "otel_events")

    assert_receive {:span, span(name: "INSERT otel_events", attributes: attributes)}
    assert %{"db.collection.name": "otel_events"} = :otel_attributes.map(attributes)
  end

  test "the operation is the command the server reported, not the first word of the text",
       %{conn: conn} do
    OpentelemetryPostgrex.setup()

    Postgrex.query!(
      conn,
      "WITH v AS (SELECT $1::text AS name) INSERT INTO otel_events SELECT name FROM v",
      ["Ada"]
    )

    assert_receive {:span, span(attributes: attributes)}
    assert %{"db.operation.name": "INSERT"} = :otel_attributes.map(attributes)
  end

  test "returned rows are only the rows the server sent back", %{conn: conn} do
    OpentelemetryPostgrex.setup()

    Postgrex.query!(conn, "INSERT INTO otel_events VALUES ($1)", ["Ada"])
    assert_receive {:span, span(name: "INSERT otel_events", attributes: attributes)}
    refute Map.has_key?(:otel_attributes.map(attributes), :"db.response.returned_rows")

    Postgrex.query!(conn, "INSERT INTO otel_events VALUES ($1) RETURNING name", ["Ada"])
    assert_receive {:span, span(name: "INSERT otel_events", attributes: attributes)}
    assert %{"db.response.returned_rows": 1} = :otel_attributes.map(attributes)
  end

  test "the summary names every operation and table, and the source is the collection only when the statement names one table",
       %{conn: conn} do
    OpentelemetryPostgrex.setup()

    Postgrex.query!(conn, "with t as (select 1) select * from t", [], source: "t")
    assert_receive {:span, span(name: "SELECT SELECT t", attributes: attributes)}
    attributes = :otel_attributes.map(attributes)
    assert %{"db.query.summary": "SELECT SELECT t", "db.collection.name": "t"} = attributes
    assert %{"db.operation.name": "SELECT"} = attributes

    Postgrex.query!(
      conn,
      "SELECT e.name FROM otel_events e JOIN pg_tables p ON e.name = p.tablename",
      [],
      source: "otel_events"
    )

    assert_receive {:span, span(name: "SELECT otel_events pg_tables", attributes: attributes)}
    refute Map.has_key?(:otel_attributes.map(attributes), :"db.collection.name")
  end

  test "a transaction's BEGIN and COMMIT are spans", %{conn: conn} do
    OpentelemetryPostgrex.setup()

    Postgrex.transaction(conn, &Postgrex.query!(&1, "SELECT 1", []))

    assert_receive {:span, span(name: "BEGIN")}
    assert_receive {:span, span(name: "SELECT")}
    assert_receive {:span, span(name: "COMMIT")}
  end

  test "each round trip of a stream is its own span", %{conn: conn} do
    OpentelemetryPostgrex.setup()

    Postgrex.transaction(conn, fn conn ->
      query = Postgrex.prepare!(conn, "", "SELECT * FROM generate_series(1, 5)")
      conn |> Postgrex.stream(query, [], max_rows: 2) |> Stream.run()
    end)

    returned_rows =
      for {:span, span(name: "SELECT generate_series", attributes: attributes)} <- spans(),
          rows = :otel_attributes.map(attributes)[:"db.response.returned_rows"],
          do: rows

    assert returned_rows == [2, 2, 1]
  end

  defp spans do
    receive do
      {:span, _} = span -> [span | spans()]
    after
      100 -> []
    end
  end

  test "a query run in a task is a child of the span that started the task", %{conn: conn} do
    OpentelemetryPostgrex.setup()

    Tracer.with_span "parent" do
      Task.await(Task.async(fn -> Postgrex.query!(conn, "SELECT 1", []) end))
    end

    assert_receive {:span, span(name: "parent", span_id: parent_span_id)}
    assert_receive {:span, span(name: "SELECT", parent_span_id: ^parent_span_id)}
  end

  test "a failed query fails its span with the SQLSTATE code", %{conn: conn} do
    OpentelemetryPostgrex.setup()

    {:error, %Postgrex.Error{}} = Postgrex.query(conn, "SELECT * FROM otel_missing", [])

    assert_receive {:span,
                    span(
                      name: "SELECT otel_missing",
                      status: {:status, :error, "42P01"},
                      attributes: attributes
                    )}

    assert %{"error.type": "42P01", "db.response.status_code": "42P01"} =
             :otel_attributes.map(attributes)
  end

  test "an error with no SQLSTATE fails its span with the error's module", %{conn: conn} do
    OpentelemetryPostgrex.setup()

    {:error, %DBConnection.TransactionError{}} =
      Postgrex.query(conn, "SELECT 1", [], mode: :savepoint)

    assert_receive {:span,
                    span(
                      status: {:status, :error, "DBConnection.TransactionError"},
                      attributes: attributes
                    )}

    refute Map.has_key?(:otel_attributes.map(attributes), :"db.response.status_code")
  end

  @tag :capture_log
  test "a query whose caller is killed fails and ends as the caller dies", %{conn: conn} do
    OpentelemetryPostgrex.setup()
    test = self()

    caller =
      spawn(fn ->
        send(test, :querying)
        Postgrex.query(conn, "SELECT pg_sleep(2)", [])
      end)

    assert_receive :querying
    Process.sleep(100)
    Process.exit(caller, :kill)

    assert_receive {:span,
                    span(
                      name: "SELECT",
                      status: {:status, :error, "_OTHER"}
                    )},
                   500
  end

  @tag :capture_log
  test "a statement that is chardata but not iodata is still traced, and tracing goes on",
       %{conn: conn} do
    OpentelemetryPostgrex.setup(query_sanitization: false)

    assert_raise ArgumentError, fn -> Postgrex.query(conn, [~c"SELECT '", 8364, ~c"'"], []) end

    assert_receive {:span,
                    span(attributes: attributes, status: {:status, :error, "ArgumentError"})}

    assert %{"db.query.text": "SELECT '€'"} = :otel_attributes.map(attributes)
    assert :telemetry.list_handlers([:postgrex, :query]) != []
  end

  test "db.query.text has every literal replaced by ? by default", %{conn: conn} do
    OpentelemetryPostgrex.setup()

    Postgrex.query!(conn, "SELECT 'Ada', 42, $1::int", [1])

    assert_receive {:span, span(attributes: attributes)}
    assert %{"db.query.text": "SELECT ?, ?, $1::int"} = :otel_attributes.map(attributes)
  end

  test "db.query.text keeps every literal when plain", %{conn: conn} do
    OpentelemetryPostgrex.setup(query_sanitization: false)

    Postgrex.query!(conn, "SELECT 'Ada', 42", [])

    assert_receive {:span, span(attributes: attributes)}
    assert %{"db.query.text": "SELECT 'Ada', 42"} = :otel_attributes.map(attributes)
  end

  test "db.query.text is left out when disabled", %{conn: conn} do
    OpentelemetryPostgrex.setup(opt_out_attrs: [:"db.query.text"])

    Postgrex.query!(conn, "SELECT 1", [])

    assert_receive {:span, span(attributes: attributes)}
    refute Map.has_key?(:otel_attributes.map(attributes), :"db.query.text")
  end

  describe "db.client.operation.duration" do
    setup do
      Process.register(self(), :otel_postgrex_metric_test)
      :ok
    end

    @tag :capture_log
    test "is not recorded for a query whose caller is killed before it finishes", %{conn: conn} do
      OpentelemetryPostgrex.setup()
      query = Postgrex.prepare!(conn, "", "SELECT pg_sleep(2)")
      test = self()

      caller =
        spawn(fn ->
          send(test, :querying)
          Postgrex.execute(conn, query, [])
        end)

      assert_receive :querying
      Process.sleep(100)
      Process.exit(caller, :kill)

      assert_receive {:span, span(name: "SELECT", status: {:status, :error, "_OTHER"})},
                     500

      Postgrex.query!(conn, "SELECT 1", [])
      :otel_meter_server.force_flush()

      assert_receive {:otel_metric,
                      metric(
                        name: :"db.client.operation.duration",
                        data: histogram(datapoints: datapoints)
                      )}

      refute Enum.any?(
               datapoints,
               &match?(histogram_datapoint(attributes: %{"error.type": "_OTHER"}), &1)
             )
    end

    test "is recorded for each query with the span's attributes", %{conn: conn} do
      OpentelemetryPostgrex.setup()

      Postgrex.query!(conn, "SELECT name FROM otel_events", [], source: "otel_events")
      {:error, _} = Postgrex.query(conn, "SELECT * FROM otel_missing", [])
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
                       "db.system.name": :postgresql,
                       "db.namespace": @database,
                       "db.operation.name": "SELECT",
                       "db.collection.name": "otel_events",
                       "db.query.summary": "SELECT otel_events"
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
                   attributes: %{"error.type": "42P01", "db.response.status_code": "42P01"}
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
