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

    on_exit(fn -> :telemetry.detach(OpentelemetryMongodbDriver) end)

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

    assert %{"server.address": address} = attributes = :otel_attributes.map(attributes)
    assert address in ["127.0.0.1", "localhost"]

    assert Map.delete(attributes, :"server.address") == %{
             "db.system.name": :mongodb,
             "db.namespace": @database,
             "db.collection.name": "users",
             "db.operation.name": "find",
             "db.query.text": ~s({"find":"users","filter":{"name":"?"}})
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

  test "a command without a collection is named after its operation and database", %{conn: conn} do
    OpentelemetryMongodbDriver.setup()

    {:ok, _} = Mongo.command(conn, ping: 1)

    assert_receive {:span, span(name: "ping " <> @database, attributes: attributes)}
    refute Map.has_key?(:otel_attributes.map(attributes), :"db.collection.name")
  end

  test "a failed command fails its span with the server's error code and leaves the values out",
       %{conn: conn} do
    OpentelemetryMongodbDriver.setup()

    {:error, %Mongo.Error{code: 59}} = Mongo.command(conn, bogusCommand: 1)

    assert_receive {:span,
                    span(
                      name: "bogusCommand " <> @database,
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

  test "a command whose connection times out fails its span with the network error",
       %{conn: conn} do
    OpentelemetryMongodbDriver.setup()
    {:ok, _} = Mongo.insert_one(conn, "users", %{name: "Ada"})

    {:error, %Mongo.Error{}} =
      Mongo.find_one(conn, "users", %{"$where" => "sleep(500) || true"}, timeout: 100)

    assert_receive {:span,
                    span(
                      name: "find users",
                      status: {:status, :error, "Mongo.Error"}
                    )}
  end

  test "a transaction's commit is a child of the span that ran the transaction", %{conn: conn} do
    OpentelemetryMongodbDriver.setup()
    {:ok, _} = Mongo.insert_one(conn, "users", %{name: "Ada"})

    Tracer.with_span "parent" do
      :ok =
        Mongo.transaction(conn, fn ->
          {:ok, _} = Mongo.insert_one(conn, "users", %{name: "Grace"})
          :ok
        end)
    end

    assert_receive {:span, span(name: "parent", span_id: parent_span_id)}
    assert_receive {:span, span(name: "commitTransaction admin", parent_span_id: ^parent_span_id)}
  end

  describe "db.query.text" do
    test "is left out when disabled", %{conn: conn} do
      OpentelemetryMongodbDriver.setup(db_query_text: :disabled)

      Mongo.find(conn, "users", %{name: "Ada"}) |> Enum.to_list()

      assert_receive {:span, span(name: "find users", attributes: attributes)}
      refute Map.has_key?(:otel_attributes.map(attributes), :"db.query.text")
    end

    test "keeps the command and its collection and replaces every other value with ? by default",
         %{conn: conn} do
      OpentelemetryMongodbDriver.setup()

      Mongo.find(conn, "users", %{name: "Ada"}) |> Enum.to_list()

      assert_receive {:span, span(name: "find users", attributes: attributes)}

      assert %{"db.query.text": text} = :otel_attributes.map(attributes)

      assert %{"find" => "users", "filter" => %{"name" => "?"}} = Jason.decode!(text)

      refute text =~ "Ada"
    end

    test "keeps the values when plain", %{conn: conn} do
      OpentelemetryMongodbDriver.setup(db_query_text: :plain)

      id = Mongo.object_id()
      encoded_id = BSON.ObjectId.encode!(id)
      Mongo.find(conn, "users", %{_id: id, name: "Ada"}) |> Enum.to_list()

      assert_receive {:span, span(name: "find users", attributes: attributes)}

      assert %{"db.query.text": text} = :otel_attributes.map(attributes)

      assert %{
               "find" => "users",
               "filter" => %{"_id" => ^encoded_id, "name" => "Ada"}
             } = Jason.decode!(text)
    end

    test "records the documents of an insert when plain", %{conn: conn} do
      OpentelemetryMongodbDriver.setup(db_query_text: :plain)

      {:ok, _} = Mongo.insert_one(conn, "users", %{name: "Ada", born: ~U[1815-12-10 00:00:00Z]})

      assert_receive {:span, span(name: "insert users", attributes: attributes)}

      assert %{"db.query.text": text} = :otel_attributes.map(attributes)

      assert %{
               "insert" => "users",
               "documents" => [%{"name" => "Ada", "born" => "1815-12-10 00:00:00Z"}]
             } =
               Jason.decode!(text)
    end

    test "keeps every key of every list item when obfuscated", %{conn: conn} do
      OpentelemetryMongodbDriver.setup(db_query_text: :obfuscated)

      {:ok, _} =
        Mongo.insert_many(conn, "users", [%{name: "Ada", tags: ["a", "b"]}, %{born: 1906}])

      assert_receive {:span, span(name: "insert users", attributes: attributes)}
      assert %{"db.query.text": text} = :otel_attributes.map(attributes)

      assert %{
               "insert" => "users",
               "documents" => [%{"name" => "?", "tags" => ["?", "?"]}, %{"born" => "?"}]
             } = Jason.decode!(text)
    end

    test "stops building the obfuscated text at 2048 bytes", %{conn: conn} do
      OpentelemetryMongodbDriver.setup(db_query_text: :obfuscated)

      documents = for i <- 1..20_000, do: %{i: i, name: "user #{i}"}
      {:ok, _} = Mongo.insert_many(conn, "users", documents)

      assert_receive {:span, span(name: "insert users", attributes: attributes)}

      assert %{"db.query.text": ~s({"insert":"users",) <> _ = text} =
               :otel_attributes.map(attributes)

      assert byte_size(text) in 2000..2048
    end

    test "is cut to its first 2048 bytes", %{conn: conn} do
      OpentelemetryMongodbDriver.setup(db_query_text: :plain)

      Mongo.find(conn, "users", %{name: String.duplicate("é", 2_000)}) |> Enum.to_list()

      assert_receive {:span, span(name: "find users", attributes: attributes)}
      assert %{"db.query.text": text} = :otel_attributes.map(attributes)
      assert byte_size(text) in 2047..2048
      assert String.valid?(text)
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
