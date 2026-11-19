defmodule OpentelemetryOban.QueueMetrics do
  @moduledoc false
  import Ecto.Query

  require OpenTelemetryAPIExperimental.ObservableGauge
  require OpenTelemetryAPIExperimental.ObservableUpDownCounter

  alias OpenTelemetry.SemConv.Incubating.MessagingAttributes
  alias OpenTelemetryAPIExperimental.ObservableGauge
  alias OpenTelemetryAPIExperimental.ObservableUpDownCounter

  @job_count :"oban.job.count"
  @queue_lag :"oban.queue.lag"

  def setup(opts) do
    unless Code.ensure_loaded?(Oban.Met) do
      raise ArgumentError, "queue_metrics needs the :oban_met dependency"
    end

    job_count =
      ObservableUpDownCounter.create(@job_count, %{
        unit: :"{job}",
        description: "Jobs in the database, by queue and state."
      })

    queue_lag =
      ObservableGauge.create(@queue_lag, %{
        unit: :s,
        description:
          "Age of each queue's oldest available job: how long it has been ready to run without running."
      })

    :otel_meter.register_callback(
      :opentelemetry_experimental.get_meter(:opentelemetry.get_application_scope(__MODULE__)),
      [job_count, queue_lag],
      &__MODULE__.observe/1,
      Keyword.fetch!(opts, :name)
    )
  end

  # Every node sees the same jobs table, so only the leader reports.
  def observe(name) do
    if safely(fn -> Oban.Peer.leader?(name) end, false) do
      [
        {@job_count, safely(fn -> job_counts(name) end, [])},
        {@queue_lag, safely(fn -> queue_lags(name) end, [])}
      ]
    else
      []
    end
  end

  # A callback that raises crashes the metric reader, and repeated crashes stop every metric.
  defp safely(fun, fallback) do
    fun.()
  rescue
    _ -> fallback
  catch
    :exit, _ -> fallback
  end

  defp job_counts(name) do
    Enum.flat_map(Oban.Job.states(), fn state ->
      name
      |> Oban.Met.latest(:full_count, group: "queue", filters: [state: to_string(state)])
      |> Enum.map(fn {queue, count} ->
        {count,
         %{
           :"messaging.system.name" => :oban,
           MessagingAttributes.messaging_destination_name() => queue,
           "oban.job.state": state
         }}
      end)
    end)
  end

  defp queue_lags(name) do
    conf = Oban.config(name)
    now = DateTime.utc_now()

    waiting =
      conf
      |> Oban.Repo.all(
        from(job in Oban.Job,
          where: job.state == "available",
          group_by: job.queue,
          select: {job.queue, min(job.scheduled_at)}
        ),
        timeout: 5_000
      )
      |> Map.new(fn {queue, scheduled_at} ->
        {queue, DateTime.diff(now, scheduled_at, :millisecond) / 1000}
      end)

    paused = paused_by_queue(name, conf)

    paused
    |> Map.new(fn {queue, _paused} -> {queue, 0} end)
    |> Map.merge(waiting)
    |> Enum.map(fn {queue, lag} ->
      {lag,
       %{
         :"messaging.system.name" => :oban,
         MessagingAttributes.messaging_destination_name() => queue,
         "oban.queue.paused": Map.get(paused, queue, false)
       }}
    end)
  end

  # The queues any node runs, and whether each is paused on every node that runs it. This node's
  # queues are checked directly; other nodes' come from the checks they gossip.
  defp paused_by_queue(name, conf) do
    local =
      Enum.map(conf.queues, fn {queue, _options} ->
        {to_string(queue), safely(fn -> Oban.check_queue(name, queue: queue).paused end, false)}
      end)

    others =
      safely(
        fn ->
          name
          |> Oban.Met.checks()
          |> Enum.filter(&(&1["name"] == inspect(name) and &1["node"] != conf.node))
          |> Enum.map(&{&1["queue"], &1["paused"] == true})
        end,
        []
      )

    (local ++ others)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {queue, paused} -> {queue, Enum.all?(paused)} end)
  end
end
