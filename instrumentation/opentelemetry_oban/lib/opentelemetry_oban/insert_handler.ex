defmodule OpentelemetryOban.InsertHandler do
  @moduledoc false

  alias OpenTelemetry.SemConv.Incubating.MessagingAttributes
  alias OpenTelemetry.Span
  alias OpentelemetryOban.Errors

  require Logger

  @tracer_id __MODULE__

  def attach() do
    :telemetry.attach_many(
      {__MODULE__, :insert},
      [
        [:oban, :engine, :insert_job, :start],
        [:oban, :engine, :insert_job, :stop],
        [:oban, :engine, :insert_job, :exception],
        [:oban, :engine, :insert_all_jobs, :start],
        [:oban, :engine, :insert_all_jobs, :stop],
        [:oban, :engine, :insert_all_jobs, :exception]
      ],
      &__MODULE__.handle_event/4,
      []
    )

    if Code.ensure_loaded?(Oban.Pro.Worker) do
      apply(Oban.Pro.Worker, :attach_hook, [__MODULE__])
    end

    :ok
  end

  def handle_event([:oban, :engine, :insert_job, :start], _measurements, metadata, _config) do
    queue = Ecto.Changeset.get_field(metadata.changeset, :queue)

    OpentelemetryTelemetry.start_telemetry_span(@tracer_id, "send #{queue}", metadata, %{
      kind: :producer,
      attributes: OpentelemetryOban.attributes_before_insert(metadata.changeset)
    })
  rescue
    exception -> warn(exception)
  end

  def handle_event([:oban, :engine, :insert_all_jobs, :start], _measurements, metadata, _config) do
    OpentelemetryTelemetry.start_telemetry_span(@tracer_id, "send", metadata, %{
      kind: :producer,
      attributes: OpentelemetryOban.attributes_before_insert_all()
    })
  rescue
    exception -> warn(exception)
  end

  def handle_event([:oban, :engine, :insert_job, :stop], _measurements, metadata, _config) do
    ctx = OpentelemetryTelemetry.set_current_telemetry_span(@tracer_id, metadata)
    Span.set_attributes(ctx, OpentelemetryOban.attributes_after_insert(metadata.job))
    OpentelemetryTelemetry.end_telemetry_span(@tracer_id, metadata)
  rescue
    exception -> warn(exception)
  end

  def handle_event([:oban, :engine, :insert_all_jobs, :stop], _measurements, metadata, _config) do
    ctx = OpentelemetryTelemetry.set_current_telemetry_span(@tracer_id, metadata)

    Span.set_attribute(
      ctx,
      MessagingAttributes.messaging_batch_message_count(),
      length(metadata.jobs)
    )

    OpentelemetryTelemetry.end_telemetry_span(@tracer_id, metadata)
  rescue
    exception -> warn(exception)
  end

  def handle_event(
        [:oban, :engine, _event, :exception],
        _measurements,
        %{kind: kind, reason: reason, stacktrace: stacktrace} = metadata,
        _config
      ) do
    ctx = OpentelemetryTelemetry.set_current_telemetry_span(@tracer_id, metadata)

    ctx
    |> Errors.record_exception(kind, reason, stacktrace)
    |> Errors.set_error_type()

    Span.set_status(
      ctx,
      OpenTelemetry.status(:error, Exception.format_banner(kind, reason, stacktrace))
    )

    OpentelemetryTelemetry.end_telemetry_span(@tracer_id, metadata)
  rescue
    exception -> warn(exception)
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

  defp warn(exception) do
    Logger.warning("OpentelemetryOban insert span failed: #{Exception.message(exception)}")
  end
end
