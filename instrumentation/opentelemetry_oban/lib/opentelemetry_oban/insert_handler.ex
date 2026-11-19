defmodule OpentelemetryOban.InsertHandler do
  @moduledoc false

  alias OpenTelemetry.SemConv.Incubating.MessagingAttributes

  require Logger

  def attach() do
    :telemetry.attach_many(
      "#{__MODULE__}.insert",
      [[:oban, :engine, :insert_job, :stop], [:oban, :engine, :insert_all_jobs, :stop]],
      &__MODULE__.handle_insert/4,
      []
    )

    if Code.ensure_loaded?(Oban.Pro.Worker) do
      apply(Oban.Pro.Worker, :attach_hook, [__MODULE__])
    end

    :ok
  end

  def handle_insert(_event, _measurements, metadata, _config) do
    metadata
    |> Map.get(:jobs, Map.get(metadata, :job))
    |> List.wrap()
    |> Enum.each(fn job ->
      OpenTelemetry.Tracer.add_event("oban.insert", %{
        MessagingAttributes.messaging_message_id() => to_string(job.id),
        MessagingAttributes.messaging_destination_name() => job.queue,
        :"oban.job.worker" => job.worker
      })
    end)
  rescue
    exception ->
      Logger.warning("OpentelemetryOban insert event failed: #{Exception.message(exception)}")
  end

  def before_new(args, opts) do
    ctx =
      case OpenTelemetry.Tracer.current_span_ctx() do
        :undefined ->
          OpentelemetryProcessPropagator.fetch_parent_ctx(
            length(Process.get(:"$callers", [])),
            :"$callers"
          ) || OpenTelemetry.Ctx.get_current()

        _span_ctx ->
          OpenTelemetry.Ctx.get_current()
      end

    carrier = Map.new(:otel_propagator_text_map.inject_from(ctx, []))
    {:ok, args, Keyword.update(opts, :meta, carrier, &Map.merge(carrier, &1))}
  rescue
    exception ->
      Logger.warning(
        "OpentelemetryOban trace propagation failed: #{Exception.message(exception)}"
      )

      {:ok, args, opts}
  end
end
