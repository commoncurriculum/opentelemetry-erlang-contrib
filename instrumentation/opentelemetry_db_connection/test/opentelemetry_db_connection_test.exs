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
      id: make_ref()
    )
  end

  defp recorded(metric_name, pool_name) do
    :otel_meter_server.force_flush()
    find_datapoint(metric_name, pool_name)
  end

  defp find_datapoint(metric_name, pool_name) do
    receive do
      {:otel_metric, metric(name: ^metric_name, unit: :s, data: histogram(datapoints: points))} ->
        Enum.find(
          points,
          &match?(
            histogram_datapoint(attributes: %{"db.client.connection.pool.name": ^pool_name}),
            &1
          )
        ) || find_datapoint(metric_name, pool_name)

      {:otel_metric, _other} ->
        find_datapoint(metric_name, pool_name)
    after
      1_000 -> flunk("no #{metric_name} datapoint for #{pool_name}")
    end
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
end
