defmodule OpentelemetryFinch.PoolMetricsTest do
  use ExUnit.Case, async: false

  require Record

  for name <- [:metric, :sum, :datapoint] do
    Record.defrecord(
      name,
      Record.extract(name, from_lib: "opentelemetry_experimental/include/otel_metrics.hrl")
    )
  end

  setup do
    bypass = Bypass.open()
    configured = Bypass.open()
    configured_url = "http://localhost:#{configured.port}"

    start_supervised!(
      {Finch,
       name: MetricsFinch,
       pools: %{
         :default => [start_pool_metrics?: true],
         configured_url => [start_pool_metrics?: true, size: 2]
       }}
    )

    OpentelemetryFinch.setup(
      pool_metrics: [name: MetricsFinch, pools: [:default, configured_url]]
    )

    Process.register(self(), :opentelemetry_finch_metrics)

    {:ok, bypass: bypass, configured: configured}
  end

  test "counts connections in use per pool until their requests finish", %{
    bypass: bypass,
    configured: configured
  } do
    test = self()

    for server <- [bypass, configured] do
      Bypass.expect_once(server, fn conn ->
        send(test, {:held, self()})

        receive do
          :release -> Plug.Conn.resp(conn, 200, "")
        end
      end)
    end

    requests =
      for server <- [bypass, configured] do
        Task.async(fn ->
          Finch.build(:get, "http://localhost:#{server.port}/") |> Finch.request(MetricsFinch)
        end)
      end

    handlers =
      for _ <- 1..2 do
        assert_receive {:held, handler}, 5_000
        handler
      end

    assert open_connections() == %{bypass.port => 1, configured.port => 1}

    Enum.each(handlers, &send(&1, :release))
    Enum.each(requests, &({:ok, %{status: 200}} = Task.await(&1)))

    assert open_connections() == %{bypass.port => 0, configured.port => 0}
  end

  defp open_connections do
    :otel_meter_server.force_flush()

    assert_receive {:otel_metric,
                    metric(
                      name: :"http.client.open_connections",
                      unit: :"{connection}",
                      data: sum(datapoints: datapoints)
                    )},
                   1_000

    Map.new(datapoints, fn point ->
      attributes = datapoint(point, :attributes)

      assert Map.delete(attributes, :"server.port") == %{
               "http.connection.state": :active,
               "server.address": "localhost",
               "url.scheme": :http
             }

      {attributes[:"server.port"], datapoint(point, :value)}
    end)
  end
end
