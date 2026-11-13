defmodule OpentelemetryMongodbDriverTest do
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

  @database "opentelemetry_mongodb_driver_test"

  setup_all do
    {:ok, conn} =
      Mongo.start_link(url: Application.fetch_env!(:opentelemetry_mongodb_driver, :url))

    {:ok, conn: conn}
  end

  setup %{conn: conn} do
    _ = Mongo.drop_collection(conn, "users")

    :otel_simple_processor.set_exporter(:otel_exporter_pid, self())

    on_exit(fn -> :telemetry.detach({OpentelemetryMongodbDriver, :execution}) end)

    :ok
  end

  test "a command is a client span named after its operation and collection, under the current span",
       %{conn: conn} do
    OpentelemetryMongodbDriver.setup()

    Tracer.with_span "parent" do
      [] = conn |> Mongo.find("users", %{name: "Ada"}) |> Enum.to_list()
    end

    assert_receive {:span, span(name: "parent", span_id: parent_span_id)}

    assert_receive {:span,
                    span(
                      name: "find users",
                      kind: :client,
                      parent_span_id: ^parent_span_id,
                      start_time: start_time,
                      end_time: end_time,
                      attributes: attributes,
                      status: :undefined
                    )}

    assert start_time < end_time

    assert :otel_attributes.map(attributes) == %{
             "db.system.name": :mongodb,
             "db.namespace": @database,
             "db.collection.name": "users",
             "db.operation.name": "find"
           }
  end

  test "a command run in a task is a child of the span that started the task", %{conn: conn} do
    OpentelemetryMongodbDriver.setup()

    Tracer.with_span "parent" do
      Task.await(Task.async(fn -> Mongo.count_documents(conn, "users", %{}) end))
    end

    assert_receive {:span, span(name: "parent", span_id: parent_span_id)}
    assert_receive {:span, span(name: "aggregate users", parent_span_id: ^parent_span_id)}
  end

  test "a command without a collection is named after its operation alone", %{conn: conn} do
    OpentelemetryMongodbDriver.setup()

    {:ok, _} = Mongo.command(conn, ping: 1)

    assert_receive {:span, span(name: "ping", attributes: attributes)}
    refute Map.has_key?(:otel_attributes.map(attributes), :"db.collection.name")
  end

  test "a failed command fails its span with the server's error code and leaves the values out",
       %{conn: conn} do
    OpentelemetryMongodbDriver.setup()

    {:error, %Mongo.Error{code: 59}} = Mongo.command(conn, bogusCommand: 1)

    assert_receive {:span,
                    span(
                      name: "bogusCommand",
                      status: {:status, :error, "59"},
                      attributes: attributes
                    )}

    assert %{"error.type": "59", "db.response.status_code": "59"} =
             :otel_attributes.map(attributes)
  end

  test "a write error fails its span with the write's error code and leaves the values out",
       %{conn: conn} do
    OpentelemetryMongodbDriver.setup()

    id = Mongo.object_id()
    {:ok, _} = Mongo.insert_one(conn, "users", %{_id: id, email: "ada@example.com"})
    {:error, %Mongo.WriteError{}} = Mongo.insert_one(conn, "users", %{_id: id})

    assert_receive {:span, span(name: "insert users", status: :undefined)}

    assert_receive {:span,
                    span(
                      name: "insert users",
                      status: {:status, :error, "11000"},
                      attributes: attributes
                    )}

    assert %{"error.type": "11000", "db.response.status_code": "11000"} =
             :otel_attributes.map(attributes)
  end

  describe "db.query.text" do
    test "is left out by default", %{conn: conn} do
      OpentelemetryMongodbDriver.setup()

      Mongo.find(conn, "users", %{name: "Ada"}) |> Enum.to_list()

      assert_receive {:span, span(name: "find users", attributes: attributes)}
      refute Map.has_key?(:otel_attributes.map(attributes), :"db.query.text")
    end

    test "replaces every value with ? when obfuscated", %{conn: conn} do
      OpentelemetryMongodbDriver.setup(db_query_text: :obfuscated)

      Mongo.find(conn, "users", %{name: "Ada"}) |> Enum.to_list()

      assert_receive {:span, span(name: "find users", attributes: attributes)}

      assert %{"db.query.text": text} = :otel_attributes.map(attributes)
      assert Jason.decode!(text) == %{"filter" => %{"name" => "?"}}
    end

    test "keeps the values when plain", %{conn: conn} do
      OpentelemetryMongodbDriver.setup(db_query_text: :plain)

      id = Mongo.object_id()
      Mongo.find(conn, "users", %{_id: id, name: "Ada"}) |> Enum.to_list()

      assert_receive {:span, span(name: "find users", attributes: attributes)}

      assert %{"db.query.text": text} = :otel_attributes.map(attributes)

      assert Jason.decode!(text) == %{
               "filter" => %{"_id" => BSON.ObjectId.encode!(id), "name" => "Ada"}
             }
    end

    test "is what a given function returns", %{conn: conn} do
      OpentelemetryMongodbDriver.setup(
        db_query_text: fn [{command, collection} | _] -> "#{command} #{collection}" end
      )

      Mongo.find(conn, "users", %{name: "Ada"}) |> Enum.to_list()

      assert_receive {:span, span(name: "find users", attributes: attributes)}
      assert %{"db.query.text": "find users"} = :otel_attributes.map(attributes)
    end
  end

  describe "db.client.operation.duration" do
    setup do
      Process.register(self(), :otel_mongodb_metric_test)
      :ok
    end

    test "is recorded for each command with the span's attributes", %{conn: conn} do
      OpentelemetryMongodbDriver.setup(db_query_text: :plain)

      Mongo.find(conn, "users", %{name: "Ada"}) |> Enum.to_list()
      {:error, _} = Mongo.command(conn, bogusCommand: 1)
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
                       "db.system.name": :mongodb,
                       "db.namespace": @database,
                       "db.collection.name": "users",
                       "db.operation.name": "find"
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
                   attributes: %{"error.type": "59", "db.response.status_code": "59"}
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
