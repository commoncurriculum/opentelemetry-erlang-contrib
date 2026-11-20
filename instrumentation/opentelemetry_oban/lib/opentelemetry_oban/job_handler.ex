defmodule OpentelemetryOban.JobHandler do
  @moduledoc false

  require OpenTelemetryAPIExperimental.Histogram

  alias OpenTelemetry.Ctx
  alias OpenTelemetry.Span
  alias OpenTelemetry.Tracer
  alias OpenTelemetry.SemConv.ErrorAttributes
  alias OpenTelemetry.SemConv.Incubating.MessagingAttributes
  alias OpenTelemetry.SemConv.Incubating.Metrics.MessagingMetrics
  alias OpenTelemetryAPIExperimental.Histogram
  alias OpentelemetryOban.Errors

  @tracer_id __MODULE__

  @process_duration_boundaries [
    0.005,
    0.01,
    0.025,
    0.05,
    0.075,
    0.1,
    0.25,
    0.5,
    0.75,
    1,
    2.5,
    5,
    7.5,
    10
  ]

  @options_schema [
    span_relationship: [
      type: {:in, [:child, :link, :none]},
      type_spec: quote(do: :child | :link | :none),
      default: :link,
      doc: """
      How spans relate to propagated parent context:
      * `:child` - Extract context and create parent-child relationships
      * `:link` - Extract context and create span links for loose coupling (default)
      * `:none` - Disable context propagation entirely
      """
    ]
  ]

  @nimble_options_schema NimbleOptions.new!(@options_schema)

  @doc false
  def options_schema do
    @options_schema
  end

  def attach(opts \\ []) do
    config =
      opts
      |> NimbleOptions.validate!(@nimble_options_schema)
      |> Enum.into(%{})

    Histogram.create(MessagingMetrics.messaging_process_duration(), %{
      unit: :s,
      description: "Duration of processing operation.",
      advisory_params: %{explicit_bucket_boundaries: @process_duration_boundaries}
    })

    attach_job_start_handler(config)
    attach_job_stop_handler(config)
    attach_job_exception_handler(config)
    attach_process_duration_handler()
  end

  # Metrics get their own handler: telemetry detaches a handler that raises, and a
  # metrics failure must not take the spans down with it.
  defp attach_process_duration_handler do
    :telemetry.attach_many(
      "#{__MODULE__}.process_duration",
      [[:oban, :job, :stop], [:oban, :job, :exception]],
      &__MODULE__.handle_process_duration/4,
      %{}
    )
  end

  defp attach_job_start_handler(config) do
    :telemetry.attach(
      "#{__MODULE__}.job_start",
      [:oban, :job, :start],
      &__MODULE__.handle_job_start/4,
      config
    )
  end

  defp attach_job_stop_handler(config) do
    :telemetry.attach(
      "#{__MODULE__}.job_stop",
      [:oban, :job, :stop],
      &__MODULE__.handle_job_stop/4,
      config
    )
  end

  defp attach_job_exception_handler(config) do
    :telemetry.attach(
      "#{__MODULE__}.job_exception",
      [:oban, :job, :exception],
      &__MODULE__.handle_job_exception/4,
      config
    )
  end

  def handle_job_start(_event, _measurements, metadata, config) do
    %{
      job: %{
        id: id,
        queue: queue,
        worker: worker,
        priority: priority,
        inserted_at: inserted_at,
        scheduled_at: scheduled_at,
        attempt: attempt,
        max_attempts: max_attempts,
        meta: job_meta,
        attempted_at: attempted_at
      }
    } = metadata

    links = setup_context_propagation(job_meta, config.span_relationship)

    attributes =
      %{
        :"messaging.system.name" => :oban,
        MessagingAttributes.messaging_operation_name() => "process",
        MessagingAttributes.messaging_client_id() => worker,
        MessagingAttributes.messaging_destination_name() => queue,
        MessagingAttributes.messaging_operation_type() =>
          MessagingAttributes.messaging_operation_type_values().process,
        :"oban.job.job_id" => id,
        :"oban.job.worker" => worker,
        :"oban.job.queue" => queue,
        :"oban.job.priority" => priority,
        :"oban.job.attempt" => attempt,
        :"oban.job.max_attempts" => max_attempts
      }
      |> OpentelemetryOban.put_message_id(id)
      |> put_timestamp(:"oban.job.inserted_at", inserted_at)
      |> put_timestamp(:"oban.job.scheduled_at", scheduled_at)
      |> put_timestamp(:"oban.job.attempted_at", attempted_at)
      |> put_workflow_id(job_meta)

    span_name = "process #{queue}"

    span_opts = %{kind: :consumer, attributes: attributes}
    span_opts = put_links(span_opts, links)

    OpentelemetryTelemetry.start_telemetry_span(@tracer_id, span_name, metadata, span_opts)
  end

  def handle_job_stop(_event, measurements, metadata, _config) do
    set_measurements_attributes(measurements)
    OpentelemetryTelemetry.end_telemetry_span(@tracer_id, metadata)
  end

  def handle_job_exception(
        _event,
        measurements,
        %{stacktrace: stacktrace, reason: reason} = metadata,
        _config
      ) do
    ctx = OpentelemetryTelemetry.set_current_telemetry_span(@tracer_id, metadata)

    Span.record_exception(ctx, reason, stacktrace)
    Span.set_status(ctx, OpenTelemetry.status(:error, ""))
    Errors.set_error_type(reason)

    set_measurements_attributes(measurements)

    OpentelemetryTelemetry.end_telemetry_span(@tracer_id, metadata)
  end

  def handle_process_duration([:oban, :job, event], %{duration: duration}, metadata, _config) do
    attributes =
      case event do
        :stop -> %{}
        :exception -> %{ErrorAttributes.error_type() => process_error_type(metadata.reason)}
      end

    Histogram.record(
      MessagingMetrics.messaging_process_duration(),
      System.convert_time_unit(duration, :native, :nanosecond) / 1_000_000_000,
      Map.merge(
        %{
          :"messaging.system.name" => :oban,
          MessagingAttributes.messaging_operation_name() => "process",
          MessagingAttributes.messaging_operation_type() =>
            MessagingAttributes.messaging_operation_type_values().process,
          MessagingAttributes.messaging_destination_name() => metadata.job.queue
        },
        attributes
      )
    )
  end

  defp process_error_type(%struct_name{} = reason) when is_exception(reason),
    do: inspect(struct_name)

  defp process_error_type(_reason), do: "_OTHER"

  defp set_measurements_attributes(%{duration: duration, queue_time: queue_time}) do
    OpenTelemetry.Tracer.set_attributes(%{
      :"oban.job.duration_us" => System.convert_time_unit(duration, :native, :microsecond),
      :"oban.job.queue_time_us" => System.convert_time_unit(queue_time, :nanosecond, :microsecond)
    })
  end

  defp put_links(span_opts, []), do: span_opts
  defp put_links(span_opts, links), do: Map.put(span_opts, :links, links)

  # Jobs run with `testing: :inline` are never persisted, so their timestamps are nil.
  defp put_timestamp(attributes, _key, nil), do: attributes

  defp put_timestamp(attributes, key, datetime),
    do: Map.put(attributes, key, DateTime.to_iso8601(datetime))

  defp put_workflow_id(attributes, job_meta) do
    case get_in(job_meta, ["workflow_id"]) do
      nil -> attributes
      workflow_id -> Map.put(attributes, :"oban.job.workflow_id", workflow_id)
    end
  end

  defp setup_context_propagation(job_meta, :child), do: extract_and_attach(job_meta)
  defp setup_context_propagation(job_meta, :link), do: link_from_propagated_ctx(job_meta)
  defp setup_context_propagation(_job_meta, :none), do: []

  defp extract_and_attach(job_meta) do
    case get_propagated_ctx(job_meta) do
      {_links, parent_ctx} when parent_ctx != :undefined ->
        Ctx.attach(parent_ctx)
        []

      {links, _undefined_ctx} ->
        links
    end
  end

  defp link_from_propagated_ctx(job_meta) do
    {links, _ctx} = get_propagated_ctx(job_meta)
    links
  end

  defp get_propagated_ctx(job_meta) do
    job_meta
    |> Map.to_list()
    |> extract_to_ctx()
  end

  defp extract_to_ctx([]) do
    {[], :undefined}
  end

  defp extract_to_ctx(headers) do
    ctx =
      Ctx.new()
      |> :otel_propagator_text_map.extract_to(headers)

    span_ctx = Tracer.current_span_ctx(ctx)

    case span_ctx do
      :undefined ->
        {[], :undefined}

      span_ctx ->
        {[OpenTelemetry.link(span_ctx)], ctx}
    end
  end
end
