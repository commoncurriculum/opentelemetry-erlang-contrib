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
    if Oban.Peer.leader?(name) do
      conf = Oban.config(name)
      [{@job_count, job_counts(name)}, {@queue_lag, queue_lags(conf)}]
    else
      []
    end
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
  rescue
    # Oban.Met starts its recorder after the Oban instance and raises until the recorder's
    # tables exist.
    RuntimeError -> []
  end

  defp queue_lags(conf) do
    now = DateTime.utc_now()

    waiting =
      conf
      |> Oban.Repo.all(
        from(job in Oban.Job,
          where: job.state == "available",
          group_by: job.queue,
          select: {job.queue, min(job.scheduled_at)}
        )
      )
      |> Map.new(fn {queue, scheduled_at} ->
        {queue, DateTime.diff(now, scheduled_at, :millisecond) / 1000}
      end)

    conf.queues
    |> Map.new(fn {queue, _options} -> {to_string(queue), 0} end)
    |> Map.merge(waiting)
    |> Enum.map(fn {queue, lag} ->
      {lag,
       %{
         :"messaging.system.name" => :oban,
         MessagingAttributes.messaging_destination_name() => queue
       }}
    end)
  end
end
