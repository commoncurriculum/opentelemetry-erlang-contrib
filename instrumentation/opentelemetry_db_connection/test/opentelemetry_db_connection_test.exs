defmodule OpentelemetryDBConnectionTest do
  use ExUnit.Case

  require Record

  for {name, spec} <-
        Record.extract_all(from_lib: "opentelemetry_experimental/include/otel_metrics.hrl") do
    Record.defrecord(name, spec)
  end

  setup_all do
    OpentelemetryDBConnection.setup()
    on_exit(fn -> :telemetry.detach(OpentelemetryDBConnection) end)
  end

  setup do
    Process.register(self(), :otel_db_connection_metric_test)
    :ok
  end

  defp clickhouse(opts) do
    start_supervised!(
      {Ch,
       [
         hostname: Application.fetch_env!(:opentelemetry_db_connection, :clickhouse_hostname),
         port: Application.fetch_env!(:opentelemetry_db_connection, :clickhouse_port)
       ] ++ opts},
      id: make_ref()
    )
  end

  defp postgres(opts) do
    start_supervised!(
      {Postgrex,
       [
         hostname: Application.fetch_env!(:opentelemetry_db_connection, :postgres_hostname),
         username: "postgres",
         password: "postgres",
         database: "postgres"
       ] ++ opts},
      id: opts[:label] || make_ref()
    )
  end

  defp recorded(metric_name, pool_name) do
    :otel_meter_server.force_flush()
    metrics = Map.merge(Process.get(:metrics, %{}), collect_metrics(), fn _, a, b -> a ++ b end)
    Process.put(:metrics, metrics)

    Enum.find(
      Map.get(metrics, metric_name, []),
      &match?(
        histogram_datapoint(attributes: %{"db.client.connection.pool.name": ^pool_name}),
        &1
      )
    ) || flunk("no #{metric_name} datapoint for #{pool_name}")
  end

  test "a ClickHouse query records its pool's wait and use time, named by the pool's label" do
    pool = clickhouse(label: OtelClickhousePool)
    Ch.query!(pool, "SELECT 1")

    assert histogram_datapoint(count: 1, attributes: attributes) =
             recorded(:"db.client.connection.wait_time", "OtelClickhousePool")

    assert attributes == %{
             "db.client.connection.pool.name": "OtelClickhousePool",
             "db.system.name": :clickhouse
           }

    assert histogram_datapoint(count: 1, sum: sum) =
             recorded(:"db.client.connection.use_time", "OtelClickhousePool")

    assert sum > 0
  end

  test "a pool with no label is named by its driver" do
    pool = postgres([])
    Postgrex.query!(pool, "SELECT 1", [])

    assert histogram_datapoint(attributes: %{"db.system.name": :postgresql}) =
             recorded(:"db.client.connection.use_time", "Postgrex.Protocol")
  end

  test "use time covers everything done with the connection checked out" do
    pool = clickhouse(label: "otel_run_pool")

    DBConnection.run(pool, fn conn ->
      Ch.query!(conn, "SELECT 1")
      Process.sleep(100)
      Ch.query!(conn, "SELECT 2")
    end)

    assert histogram_datapoint(count: 1, sum: sum) =
             recorded(:"db.client.connection.use_time", "otel_run_pool")

    assert sum >= 0.1
  end

  test "wait time covers the time spent queued for a busy connection" do
    pool = clickhouse(label: "otel_queue_pool", pool_size: 1)
    test = self()

    Task.start(fn ->
      DBConnection.run(pool, fn _conn ->
        send(test, :holding)
        Process.sleep(100)
      end)
    end)

    assert_receive :holding
    Ch.query!(pool, "SELECT 1")

    assert histogram_datapoint(count: 2, max: max) =
             recorded(:"db.client.connection.wait_time", "otel_queue_pool")

    assert max >= 0.09
  end

  test "a caller dropped from the queue counts a timeout and records no wait time" do
    pool =
      postgres(label: "otel_dropped_pool", pool_size: 1, queue_target: 10, queue_interval: 10)

    connected? = fn -> match?({:ok, _}, Postgrex.query(pool, "SELECT 1", [])) end
    assert Enum.any?(1..100, fn _ -> connected?.() || (Process.sleep(20) && false) end)
    :otel_meter_server.force_flush()
    collect_metrics()
    test = self()

    Task.start(fn ->
      DBConnection.run(pool, fn _conn ->
        send(test, :holding)
        Process.sleep(300)
      end)
    end)

    assert_receive :holding, 2_000

    assert_raise DBConnection.ConnectionError, fn ->
      Postgrex.query!(pool, "SELECT 1", [], queue_target: 10, queue_interval: 10)
    end

    :otel_meter_server.force_flush()
    metrics = collect_metrics()

    pool_attributes = %{
      "db.client.connection.pool.name": "otel_dropped_pool",
      "db.system.name": :postgresql
    }

    refute Enum.any?(
             metrics[:"db.client.connection.wait_time"],
             &match?(
               histogram_datapoint(attributes: %{"error.type": _}),
               &1
             )
           )

    assert Enum.any?(metrics[:"db.client.connection.timeouts"], &(elem(&1, 1) == pool_attributes))
  end

  test "a caller whose deadline passes while it is queued counts a timeout" do
    pool = postgres(label: "otel_deadline_pool", pool_size: 1, queue_target: 1_000)

    connected? = fn -> match?({:ok, _}, Postgrex.query(pool, "SELECT 1", [])) end
    assert Enum.any?(1..100, fn _ -> connected?.() || (Process.sleep(20) && false) end)
    :otel_meter_server.force_flush()
    collect_metrics()
    test = self()

    Task.start(fn ->
      DBConnection.run(pool, fn _conn ->
        send(test, :holding)
        Process.sleep(200)
      end)
    end)

    assert_receive :holding, 2_000

    assert_raise DBConnection.ConnectionError, ~r/deadline reached while in queue/, fn ->
      Postgrex.query!(pool, "SELECT 1", [], timeout: 50)
    end

    :otel_meter_server.force_flush()

    timeouts = collect_metrics()[:"db.client.connection.timeouts"]

    assert Enum.any?(
             timeouts,
             &(elem(&1, 1) == %{
                 "db.client.connection.pool.name": "otel_deadline_pool",
                 "db.system.name": :postgresql
               })
           )
  end

  test "a running pool reports its connections, size and queued callers until it stops" do
    pool = postgres(label: "otel_gauge_pool", pool_size: 1)

    connected? = fn -> match?({:ok, _}, Postgrex.query(pool, "SELECT 1", [])) end
    assert Enum.any?(1..100, fn _ -> connected?.() || (Process.sleep(20) && false) end)

    attributes = %{
      "db.client.connection.pool.name": "otel_gauge_pool",
      "db.system.name": :postgresql
    }

    assert pool_gauges(attributes) == %{
             "db.client.connection.count": %{idle: 1, used: 0},
             "db.client.connection.max": [1],
             "db.client.connection.pending_requests": [0]
           }

    test = self()

    Task.start(fn ->
      DBConnection.run(pool, fn _conn ->
        send(test, :holding)
        Process.sleep(500)
      end)
    end)

    assert_receive :holding, 2_000
    Task.start(fn -> Postgrex.query(pool, "SELECT 1", []) end)
    Process.sleep(50)

    assert pool_gauges(attributes) == %{
             "db.client.connection.count": %{idle: 0, used: 1},
             "db.client.connection.max": [1],
             "db.client.connection.pending_requests": [1]
           }

    stop_supervised!("otel_gauge_pool")

    assert pool_gauges(attributes) == %{
             "db.client.connection.count": %{},
             "db.client.connection.max": [],
             "db.client.connection.pending_requests": []
           }
  end

  defp pool_gauges(attributes) do
    :otel_meter_server.force_flush()
    metrics = collect_metrics()

    values = fn name ->
      for datapoint(value: value, attributes: datapoint_attributes) <- Map.get(metrics, name, []),
          {state, ^attributes} <- [Map.pop(datapoint_attributes, :"db.client.connection.state")],
          do: {state, value}
    end

    %{
      "db.client.connection.count": Map.new(values.(:"db.client.connection.count")),
      "db.client.connection.max": Keyword.values(values.(:"db.client.connection.max")),
      "db.client.connection.pending_requests":
        Keyword.values(values.(:"db.client.connection.pending_requests"))
    }
  end

  defp collect_metrics(acc \\ %{}) do
    receive do
      {:otel_metric, metric(name: name, data: data)} ->
        collect_metrics(Map.update(acc, name, elem(data, 1), &(&1 ++ elem(data, 1))))
    after
      200 -> acc
    end
  end
end
