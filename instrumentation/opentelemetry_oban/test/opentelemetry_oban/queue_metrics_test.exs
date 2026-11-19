defmodule OpentelemetryOban.QueueMetricsTest do
  use DataCase

  require Record

  for name <- [:metric, :sum, :gauge, :datapoint] do
    Record.defrecord(
      name,
      Record.extract(name, from_lib: "opentelemetry_experimental/include/otel_metrics.hrl")
    )
  end

  setup do
    readers = Application.get_env(:opentelemetry_experimental, :readers)
    :ok = Application.stop(:opentelemetry_experimental)

    Application.put_env(:opentelemetry_experimental, :readers, [
      %{module: :otel_metric_reader, config: %{exporter: {:otel_metric_exporter_pid, self()}}}
    ])

    {:ok, _} = Application.ensure_all_started(:opentelemetry_experimental)

    on_exit(fn ->
      :ok = Application.stop(:opentelemetry_experimental)
      Application.put_env(:opentelemetry_experimental, :readers, readers)
      {:ok, _} = Application.ensure_all_started(:opentelemetry_experimental)
    end)

    # Other tests detach Oban.Met's auto-start handler, so start it here every time.
    TestHelpers.remove_oban_handlers()

    start_supervised!(
      {Oban,
       name: MetricsOban,
       repo: TestRepo,
       notifier: Oban.Notifiers.PG,
       peer: Oban.Peers.Isolated,
       testing: :disabled,
       plugins: [],
       queues: [alpha: [limit: 1, paused: true], beta: [limit: 1, paused: true]]}
    )

    start_supervised!({Oban.Met, conf: Oban.config(MetricsOban)})

    OpentelemetryOban.setup(job: :disabled, plugin: :disabled, queue_metrics: [name: MetricsOban])

    :ok
  end

  test "reports job counts by queue and state, and how long each queue's oldest available job has waited" do
    Oban.insert!(MetricsOban, TestJob.new(%{}, queue: :alpha, scheduled_at: ago(30)))
    Oban.insert!(MetricsOban, TestJob.new(%{}, queue: :alpha))
    Oban.insert!(MetricsOban, TestJob.new(%{}, queue: :gamma, scheduled_at: ago(10)))
    Oban.insert!(MetricsOban, TestJob.new(%{}, queue: :gamma, schedule_in: 3600))

    expected = %{
      {"alpha", :available} => 2,
      {"gamma", :available} => 1,
      {"gamma", :scheduled} => 1
    }

    {counts, lags} = await_job_counts(expected)
    assert counts == expected

    assert Map.keys(lags) == ["alpha", "beta", "gamma"]
    assert {alpha, true} = lags["alpha"]
    assert alpha >= 30 and alpha < 40
    assert lags["beta"] == {0, true}
    assert {gamma, false} = lags["gamma"]
    assert gamma >= 10 and gamma < 20
  end

  test "a resumed queue's lag is no longer marked paused" do
    :ok = Oban.resume_queue(MetricsOban, queue: :beta)

    lags = await_lags(&(&1["beta"] == {0, false}))
    assert lags["alpha"] == {0, true}
    assert lags["beta"] == {0, false}
  end

  test "reports nothing, and doesn't raise, when the Oban instance is gone" do
    assert OpentelemetryOban.QueueMetrics.observe(NoSuchOban) == []
  end

  test "reports nothing from a node that isn't the leader" do
    MetricsOban |> Oban.Registry.whereis(Oban.Peer) |> Agent.update(&%{&1 | leader?: false})
    refute Oban.Peer.leader?(MetricsOban)

    :otel_meter_server.force_flush()

    assert_receive {:otel_metric, metric(name: :"oban.job.count", data: sum(datapoints: []))},
                   1_000

    assert_receive {:otel_metric, metric(name: :"oban.queue.lag", data: gauge(datapoints: []))},
                   1_000
  end

  defp ago(seconds), do: DateTime.add(DateTime.utc_now(), -seconds)

  # Oban.Met counts on its own interval, and jobs inserted with a past scheduled_at stay
  # scheduled until Oban stages them.
  defp await_job_counts(expected, attempts \\ 50) do
    {counts, lags} = collect()

    if counts == expected or attempts == 0 do
      {counts, lags}
    else
      Process.sleep(100)
      await_job_counts(expected, attempts - 1)
    end
  end

  # Resuming a queue reaches its producer through the notifier.
  defp await_lags(done?, attempts \\ 50) do
    {_counts, lags} = collect()

    if done?.(lags) or attempts == 0 do
      lags
    else
      Process.sleep(100)
      await_lags(done?, attempts - 1)
    end
  end

  defp collect do
    :otel_meter_server.force_flush()

    assert_receive {:otel_metric,
                    metric(name: :"oban.job.count", data: sum(datapoints: count_points))},
                   1_000

    assert_receive {:otel_metric,
                    metric(name: :"oban.queue.lag", data: gauge(datapoints: lag_points))},
                   1_000

    counts =
      count_points
      |> Enum.reject(&(datapoint(&1, :value) == 0))
      |> Map.new(fn point ->
        attributes = datapoint(point, :attributes)
        assert attributes[:"messaging.system.name"] == :oban

        {{attributes[:"messaging.destination.name"], attributes[:"oban.job.state"]},
         datapoint(point, :value)}
      end)

    lags =
      Map.new(lag_points, fn point ->
        attributes = datapoint(point, :attributes)

        {attributes[:"messaging.destination.name"],
         {datapoint(point, :value), attributes[:"oban.queue.paused"]}}
      end)

    {counts, lags}
  end
end
