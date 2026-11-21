defmodule OpentelemetryOban.PluginHandler do
  @moduledoc false

  alias OpenTelemetry.Tracer
  alias OpenTelemetry.Span
  alias OpentelemetryOban.Errors

  @tracer_id __MODULE__

  def attach() do
    attach_plugin_start_handler()
    attach_plugin_stop_handler()
    attach_plugin_exception_handler()
  end

  defp attach_plugin_start_handler() do
    :telemetry.attach(
      "#{__MODULE__}.plugin_start",
      [:oban, :plugin, :start],
      &__MODULE__.handle_plugin_start/4,
      []
    )
  end

  defp attach_plugin_stop_handler() do
    :telemetry.attach(
      "#{__MODULE__}.plugin_stop",
      [:oban, :plugin, :stop],
      &__MODULE__.handle_plugin_stop/4,
      []
    )
  end

  defp attach_plugin_exception_handler() do
    :telemetry.attach(
      "#{__MODULE__}.plugin_exception",
      [:oban, :plugin, :exception],
      &__MODULE__.handle_plugin_exception/4,
      []
    )
  end

  def handle_plugin_start(_event, _measurements, %{plugin: plugin} = metadata, _config) do
    OpentelemetryTelemetry.start_telemetry_span(
      @tracer_id,
      "#{inspect(plugin)} process",
      metadata,
      %{attributes: %{"oban.plugin": inspect(plugin)}}
    )
  end

  def handle_plugin_stop(_event, _measurements, metadata, _config) do
    Tracer.set_attributes(end_span_plugin_attrs(metadata))
    maybe_record_stop_error(metadata)
    OpentelemetryTelemetry.end_telemetry_span(@tracer_id, metadata)
  end

  def handle_plugin_exception(
        _event,
        _measurements,
        %{kind: kind, reason: reason, stacktrace: stacktrace} = metadata,
        _config
      ) do
    ctx = OpentelemetryTelemetry.set_current_telemetry_span(@tracer_id, metadata)

    error = Errors.record_exception(ctx, kind, reason, stacktrace)

    Span.set_status(
      ctx,
      OpenTelemetry.status(:error, Exception.format_banner(kind, reason, stacktrace))
    )

    Errors.set_error_type(error)

    OpentelemetryTelemetry.end_telemetry_span(@tracer_id, metadata)
  end

  # Plugins report failure through the `{:error, meta}` return value of `:telemetry.span/3`, which
  # emits a `:stop` event carrying `:error` instead of an `:exception` event.
  #
  # `Oban.Reindexer` (formerly `Oban.Plugins.Reindexer`) has no `else` branch for the non-leader
  # case, so every follower node reports `nil` on each scheduled run. That is a no-op rather than
  # a failure, and it carries no diagnostic value, so it is not recorded as an error.
  defp maybe_record_stop_error(%{error: nil}), do: :ok

  defp maybe_record_stop_error(%{error: error}) do
    reason = unwrap_error(error)

    Tracer.set_status(OpenTelemetry.status(:error, format_error(reason)))
    Errors.set_error_type(reason)
  end

  defp maybe_record_stop_error(_metadata), do: :ok

  # Most plugins put their whole `{:error, reason}` return value under `:error`; `Oban.Stager`
  # destructures it and puts the bare reason.
  defp unwrap_error({:error, reason}), do: reason
  defp unwrap_error(error), do: error

  defp format_error(error) when is_exception(error), do: Exception.message(error)
  defp format_error(error), do: inspect(error)

  # TODO: both of the following are candidates for a future breaking change, whenever a major
  # version is on the table.
  #
  #   * The attribute keys below keep the `oban.plugins.*` namespace even though Oban moved these
  #     modules to the top level, so that existing dashboards keep working. Aligning the keys with
  #     the new module names would read more consistently, at the cost of breaking every consumer.
  #   * A metadata key that is absent currently reports a count of `0` instead of being omitted, so
  #     a genuine zero and "Oban reported nothing" are indistinguishable. If Oban ever changes the
  #     metadata a renamed plugin emits, the normalization below would report zeros rather than
  #     nothing. Omitting the attribute when its key is missing is safer, but changes the output
  #     users see today.

  # Oban 2.24 renamed Cron, Lifeline, Pruner and Reindexer to the top level and left the old
  # `Oban.Plugins.*` modules as deprecated delegates. A legacy name passed in `:plugins` still
  # runs the renamed module, so the metadata here always carries the new name; this map lets
  # attribute selection recognise either name while keeping the emitted attribute keys unchanged.
  @renamed_plugins %{
    Oban.Cron => Oban.Plugins.Cron,
    Oban.Lifeline => Oban.Plugins.Lifeline,
    Oban.Pruner => Oban.Plugins.Pruner,
    Oban.Reindexer => Oban.Plugins.Reindexer
  }

  defp end_span_plugin_attrs(%{plugin: plugin} = metadata) do
    canonical = Map.get(@renamed_plugins, plugin, plugin)
    plugin_attrs(canonical, metadata)
  end

  defp end_span_plugin_attrs(_) do
    %{}
  end

  defp plugin_attrs(Oban.Plugins.Cron, metadata) do
    %{"oban.plugins.cron.jobs_count": length(metadata[:jobs] || [])}
  end

  defp plugin_attrs(Oban.Plugins.Gossip, metadata) do
    %{"oban.plugins.gossip.gossip_count": metadata[:gossip_count]}
  end

  defp plugin_attrs(Oban.Plugins.Lifeline, metadata) do
    %{
      "oban.plugins.lifeline.discarded_count": length(metadata[:discarded_jobs] || []),
      "oban.plugins.lifeline.rescued_count": length(metadata[:rescued_jobs] || [])
    }
  end

  defp plugin_attrs(Oban.Plugins.Pruner, metadata) do
    %{"oban.plugins.pruner.pruned_count": metadata[:pruned_count]}
  end

  defp plugin_attrs(Oban.Pro.Plugins.DynamicCron, metadata) do
    %{"oban.pro.plugins.dynamic_cron.jobs_count": length(metadata[:jobs] || [])}
  end

  defp plugin_attrs(Oban.Pro.Plugins.DynamicLifeline, metadata) do
    %{
      "oban.pro.plugins.dynamic_lifeline.discarded_count":
        length(metadata[:discarded_jobs] || []),
      "oban.pro.plugins.dynamic_lifeline.rescued_count": length(metadata[:rescued_jobs] || [])
    }
  end

  defp plugin_attrs(Oban.Pro.Plugins.DynamicPrioritizer, metadata) do
    %{"oban.pro.plugins.dynamic_prioritizer.reprioritized_count": metadata[:reprioritized_count]}
  end

  defp plugin_attrs(Oban.Pro.Plugins.DynamicPruner, metadata) do
    %{"oban.pro.plugins.dynamic_pruner.pruned_count": metadata[:pruned_count]}
  end

  defp plugin_attrs(Oban.Pro.Plugins.DynamicScaler, metadata) do
    %{
      "oban.pro.plugins.dynamic_scaler.scaler.last_scaled_to": metadata[:scaler][:last_scaled_to],
      "oban.pro.plugins.dynamic_scaler.scaler.last_scaled_at":
        DateTime.to_iso8601(metadata[:scaler][:last_scaled_at])
    }
  end

  defp plugin_attrs(_plugin, _metadata) do
    %{}
  end
end
