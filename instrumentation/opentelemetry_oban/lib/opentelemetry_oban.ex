defmodule OpentelemetryOban do
  @moduledoc """
  OpentelemetryOban uses [telemetry](https://hexdocs.pm/telemetry/) handlers to
  create `OpenTelemetry` spans from Oban events.

  Supported events include job start/stop and also when an exception is raised.

  ## Usage

  In your application start:

      def start(_type, _args) do
        OpentelemetryOban.setup()

        # ...
      end
  """

  alias Ecto.Changeset
  alias Ecto.Multi
  alias OpenTelemetry.Span
  alias OpenTelemetry.SemConv.ErrorAttributes
  alias OpenTelemetry.SemConv.Incubating.MessagingAttributes

  require Logger
  require OpenTelemetry.Tracer

  @type job_options() ::
          [unquote(NimbleOptions.option_typespec(OpentelemetryOban.JobHandler.options_schema()))]
          | :disabled

  @type plugin_options() :: [] | :disabled

  @type internal_options() :: [] | :disabled

  @type insert_options() :: [] | :disabled

  @options_schema [
    job: [
      type:
        {:or,
         [
           {:keyword_list, OpentelemetryOban.JobHandler.options_schema()},
           {:in, [:disabled]}
         ]},
      type_spec: quote(do: job_options()),
      default: [],
      doc: """
      Job handler configuration. Set to `:disabled` to skip job handler setup. \n\n#{NimbleOptions.docs(OpentelemetryOban.JobHandler.options_schema(), nest_level: 1)}
      """
    ],
    plugin: [
      type: {:in, [[], :disabled]},
      type_spec: quote(do: plugin_options()),
      default: [],
      doc: "Plugin handler configuration. Set to `:disabled` to skip plugin handler setup."
    ],
    internal: [
      type: {:in, [[], :disabled]},
      type_spec: quote(do: internal_options()),
      default: :disabled,
      doc: """
      Internal handler configuration. Traces Oban's engine, notifier and peer work, such as
      fetching, staging and acknowledging jobs, so the queries it makes have a parent span.
      Off by default, because Oban polls every queue on every node; set to `[]` to turn it on.
      """
    ],
    insert: [
      type: {:in, [[], :disabled]},
      type_spec: quote(do: insert_options()),
      default: :disabled,
      doc: """
      Traces inserts made with plain `Oban.insert/2` and `Oban.insert_all/2`, so callers need no
      wrapper. Each inserted job adds an `oban.insert` event to the current span. With Oban Pro
      loaded, a global worker hook also writes the current trace context into the job's meta, so
      the job's `process` span links to the trace that enqueued it; a process with no span of its
      own uses its `$callers`' context. Set to `[]` to turn it on.
      """
    ],
    queue_metrics: [
      type:
        {:or,
         [
           {:keyword_list,
            [name: [type: :any, required: true, doc: "The Oban instance's name."]]},
           {:in, [:disabled]}
         ]},
      type_spec: quote(do: [name: Oban.name()] | :disabled),
      default: :disabled,
      doc: """
      Reports `oban.job.count` (jobs by queue and `oban.job.state`, from `Oban.Met`) and
      `oban.queue.lag` (seconds since each queue's oldest available job became ready; 0 for a
      queue any node runs with none waiting; `oban.queue.paused` is true when every node running
      the queue has it paused) for one Oban instance, such as `[name: Oban]`. Only the
      instance's leader reports, since every node sees the same jobs table. A failed read, such as
      a database timeout, reports nothing for that export instead of raising. Needs the `:oban_met`
      dependency.
      """
    ]
  ]

  @nimble_options_schema NimbleOptions.new!(@options_schema)

  @doc """
  Initializes and configures telemetry handlers.

  Note that if you don't trace plugins, but inside the plugins, there are spans
  from other instrumentation libraries (e.g. ecto) then these will still be
  traced. This setting controls only the spans that are created by
  opentelemetry_oban.

  ## Options

  #{NimbleOptions.docs(@nimble_options_schema)}
  """
  @spec setup(unquote(NimbleOptions.option_typespec(@options_schema))) :: :ok
  def setup(opts \\ []) do
    opts =
      opts
      |> normalize_legacy_opts()
      |> NimbleOptions.validate!(@nimble_options_schema)
      |> Enum.into(%{})

    if opts.job != :disabled do
      OpentelemetryOban.JobHandler.attach(opts.job)
    end

    if opts.plugin != :disabled do
      OpentelemetryOban.PluginHandler.attach()
    end

    if opts.internal != :disabled do
      OpentelemetryOban.InternalHandler.attach()
    end

    if opts.insert != :disabled do
      OpentelemetryOban.InsertHandler.attach()
    end

    if opts.queue_metrics != :disabled do
      OpentelemetryOban.QueueMetrics.setup(opts.queue_metrics)
    end

    :ok
  end

  def insert(name \\ Oban, changeset, opts \\ [])

  def insert(name, %Changeset{} = changeset, opts) do
    attributes = attributes_before_insert(changeset)
    queue = Changeset.get_field(changeset, :queue)

    OpenTelemetry.Tracer.with_span "send #{queue}", attributes: attributes, kind: :producer do
      changeset = add_tracing_information_to_meta(changeset)

      case Oban.insert(name, changeset, opts) do
        {:ok, job} ->
          OpenTelemetry.Tracer.set_attributes(attributes_after_insert(job))
          {:ok, job}

        other ->
          other
      end
    end
  end

  def insert(%Multi{} = multi, multi_name, changeset_or_fun) do
    Oban.insert(multi, multi_name, changeset_or_fun)
  end

  def insert(name, multi, multi_name, changeset_or_fun) do
    Oban.insert(name, multi, multi_name, changeset_or_fun)
  end

  def insert(name, multi, multi_name, changeset_or_fun, opts) do
    Oban.insert(name, multi, multi_name, changeset_or_fun, opts)
  end

  def insert!(name \\ Oban, %Changeset{} = changeset, opts \\ []) do
    attributes = attributes_before_insert(changeset)
    queue = Changeset.get_field(changeset, :queue)

    OpenTelemetry.Tracer.with_span "send #{queue}", attributes: attributes, kind: :producer do
      changeset = add_tracing_information_to_meta(changeset)

      try do
        job = Oban.insert!(name, changeset, opts)
        OpenTelemetry.Tracer.set_attributes(attributes_after_insert(job))
        job
      rescue
        exception ->
          ctx = OpenTelemetry.Tracer.current_span_ctx()
          Span.record_exception(ctx, exception, __STACKTRACE__)
          Span.set_status(ctx, OpenTelemetry.status(:error, ""))
          Span.set_attribute(ctx, ErrorAttributes.error_type(), inspect(exception.__struct__))
          reraise exception, __STACKTRACE__
      end
    end
  end

  def insert_all(name \\ Oban, changesets_or_wrapper, opts \\ [])

  def insert_all(name, %{changesets: changesets}, opts) when is_list(changesets) do
    insert_all(name, changesets, opts)
  end

  def insert_all(name, changesets, opts) when is_list(changesets) do
    attrs = %{
      MessagingAttributes.messaging_system() => :oban,
      MessagingAttributes.messaging_operation_name() => "send",
      MessagingAttributes.messaging_operation_type() =>
        MessagingAttributes.messaging_operation_type_values().create,
      MessagingAttributes.messaging_batch_message_count() => length(changesets)
    }

    OpenTelemetry.Tracer.with_span "send", attributes: attrs, kind: :producer do
      changesets = Enum.map(changesets, &add_tracing_information_to_meta/1)
      Oban.insert_all(name, changesets, opts)
    end
  end

  def insert_all(%Multi{} = multi, multi_name, changesets_or_wrapper) do
    Oban.insert_all(multi, multi_name, changesets_or_wrapper)
  end

  def insert_all(name, multi, multi_name, changesets_or_wrapper) do
    Oban.insert_all(name, multi, multi_name, changesets_or_wrapper)
  end

  def insert_all(name, multi, multi_name, changesets_or_wrapper, opts) do
    Oban.insert_all(name, multi, multi_name, changesets_or_wrapper, opts)
  end

  defp normalize_legacy_opts(opts) do
    case Keyword.pop(opts, :trace) do
      {nil, opts} ->
        opts

      {trace, opts} ->
        Logger.warning(
          "OpentelemetryOban.setup/1 :trace option is deprecated, use :job and :plugin options instead"
        )

        opts
        |> disable_unless_traced(trace, :jobs, :job)
        |> disable_unless_traced(trace, :plugins, :plugin)
    end
  end

  defp disable_unless_traced(opts, trace, legacy_key, new_key) do
    if legacy_key in trace do
      opts
    else
      Keyword.put_new(opts, new_key, :disabled)
    end
  end

  defp add_tracing_information_to_meta(changeset) do
    meta = Changeset.get_field(changeset, :meta, %{})

    new_meta =
      []
      |> :otel_propagator_text_map.inject()
      |> Enum.into(meta)

    Changeset.change(changeset, %{meta: new_meta})
  end

  defp attributes_before_insert(changeset) do
    queue = Changeset.get_field(changeset, :queue)
    worker = Changeset.get_field(changeset, :worker)

    %{
      MessagingAttributes.messaging_system() => :oban,
      MessagingAttributes.messaging_operation_name() => "send",
      MessagingAttributes.messaging_client_id() => worker,
      MessagingAttributes.messaging_destination_name() => queue,
      MessagingAttributes.messaging_operation_type() =>
        MessagingAttributes.messaging_operation_type_values().create,
      :"oban.job.worker" => worker
    }
  end

  defp attributes_after_insert(job) do
    %{
      MessagingAttributes.messaging_message_id() => job.id,
      "oban.job.job_id": job.id,
      "oban.job.priority": job.priority || 0,
      "oban.job.max_attempts": job.max_attempts
    }
  end
end
