defmodule OpentelemetryOban.InternalHandler do
  @moduledoc false

  alias OpenTelemetry.Span
  alias OpenTelemetry.SemConv.Incubating.MessagingAttributes
  alias OpentelemetryOban.Errors

  @tracer_id __MODULE__

  @events [
    [:engine, :init],
    [:engine, :refresh],
    [:engine, :shutdown],
    [:engine, :put_meta],
    [:engine, :check_meta],
    [:engine, :check_available],
    [:engine, :cancel_all_jobs],
    [:engine, :delete_all_jobs],
    [:engine, :fetch_jobs],
    [:engine, :insert_all_jobs],
    [:engine, :prune_jobs],
    [:engine, :rescue_jobs],
    [:engine, :retry_all_jobs],
    [:engine, :stage_jobs],
    [:engine, :cancel_job],
    [:engine, :complete_job],
    [:engine, :delete_job],
    [:engine, :discard_job],
    [:engine, :error_job],
    [:engine, :insert_job],
    [:engine, :retry_job],
    [:engine, :snooze_job],
    [:engine, :update_job],
    [:notifier, :notify],
    [:peer, :election]
  ]

  def attach() do
    :telemetry.attach_many(
      {__MODULE__, :internal},
      Enum.flat_map(@events, fn event ->
        Enum.map([:start, :stop, :exception], &([:oban | event] ++ [&1]))
      end),
      &__MODULE__.handle_event/4,
      []
    )
  end

  def handle_event([:oban, area, operation, :start], _measurements, metadata, _config) do
    OpentelemetryTelemetry.start_telemetry_span(
      @tracer_id,
      "oban.#{area}.#{operation}",
      metadata,
      %{kind: :internal, attributes: attributes(metadata)}
    )
  end

  def handle_event([:oban, _area, _operation, :stop], _measurements, metadata, _config) do
    OpentelemetryTelemetry.end_telemetry_span(@tracer_id, metadata)
  end

  def handle_event(
        [:oban, _area, _operation, :exception],
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
  end

  defp attributes(metadata) do
    %{MessagingAttributes.messaging_system() => :oban}
    |> put_queue(metadata)
  end

  defp put_queue(attributes, %{job: %{queue: queue}}), do: put_destination(attributes, queue)
  defp put_queue(attributes, %{meta: %{queue: queue}}), do: put_destination(attributes, queue)

  defp put_queue(attributes, %{changeset: changeset}),
    do: put_destination(attributes, Ecto.Changeset.get_field(changeset, :queue))

  defp put_queue(attributes, _metadata), do: attributes

  defp put_destination(attributes, queue),
    do: Map.put(attributes, MessagingAttributes.messaging_destination_name(), queue)
end
