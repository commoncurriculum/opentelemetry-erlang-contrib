defmodule OpentelemetryOban.InternalHandler do
  @moduledoc false

  alias OpenTelemetry.Span
  alias OpenTelemetry.SemConv.ErrorAttributes
  alias OpenTelemetry.SemConv.Incubating.MessagingAttributes

  @tracer_id __MODULE__

  @events [
    [:engine, :init],
    [:engine, :refresh],
    [:engine, :put_meta],
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
    [:notifier, :notify],
    [:peer, :election]
  ]

  def attach() do
    :telemetry.attach_many(
      {__MODULE__, :internal},
      Enum.flat_map(@events, fn event ->
        [[:oban | event ++ [:start]], [:oban | event ++ [:stop]], [:oban | event ++ [:exception]]]
      end),
      &__MODULE__.handle_event/4,
      []
    )
  end

  def handle_event([:oban | event], _measurements, metadata, _config) do
    {phase, name} = List.pop_at(event, -1)

    case phase do
      :start ->
        OpentelemetryTelemetry.start_telemetry_span(
          @tracer_id,
          Enum.join([:oban | name], "."),
          metadata,
          %{kind: :internal, attributes: attributes(metadata)}
        )

      :stop ->
        OpentelemetryTelemetry.end_telemetry_span(@tracer_id, metadata)

      :exception ->
        %{kind: kind, reason: reason, stacktrace: stacktrace} = metadata
        ctx = OpentelemetryTelemetry.set_current_telemetry_span(@tracer_id, metadata)
        exception = Exception.normalize(kind, reason, stacktrace)

        if is_exception(exception) do
          Span.record_exception(ctx, exception, stacktrace, [])
          Span.set_attribute(ctx, ErrorAttributes.error_type(), inspect(exception.__struct__))
        else
          Span.set_attribute(ctx, ErrorAttributes.error_type(), "_OTHER")
        end

        Span.set_status(
          ctx,
          OpenTelemetry.status(:error, Exception.format_banner(kind, reason, stacktrace))
        )

        OpentelemetryTelemetry.end_telemetry_span(@tracer_id, metadata)
    end
  end

  defp attributes(metadata) do
    queue =
      case metadata do
        %{queue: queue} when not is_nil(queue) -> to_string(queue)
        %{job: %{queue: queue}} -> queue
        %{meta: %{queue: queue}} -> queue
        %{changeset: %{changes: %{queue: queue}}} -> queue
        _ -> nil
      end

    %{
      MessagingAttributes.messaging_system() => :oban,
      MessagingAttributes.messaging_destination_name() => queue
    }
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end
end
