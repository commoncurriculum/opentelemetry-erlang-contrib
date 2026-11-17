defmodule OpentelemetryMongodbDriver do
  @moduledoc """
  Traces [mongodb_driver](https://hex.pm/packages/mongodb_driver) commands with OpenTelemetry.

  Every command the driver reports on its `[:mongodb_driver, :command, :start | :stop |
  :exception]` telemetry events becomes a `CLIENT` span and a `db.client.operation.duration`
  measurement. That covers network errors and timeouts as well as server errors. The span is a
  child of the current span of the process that ran the command, or, for a transaction's commit
  or abort, of the process that ran the transaction. Requires the `:opentelemetry_telemetry`
  application, whose span store ends the span of a caller that exits mid-command.

  ## Usage

  In your application start:

      def start(_type, _args) do
        OpentelemetryMongodbDriver.setup()

        # ...
      end

  ## Attributes

  Spans follow the [MongoDB semantic conventions](https://opentelemetry.io/docs/specs/semconv/database/mongodb/):

    * `db.system.name` - `mongodb`
    * `db.namespace` - the database
    * `db.collection.name` - the collection, when the command names one
    * `db.operation.name` - the command, such as `find` or `findAndModify`
    * `server.address` and `server.port` - the server; the port is left out when it is 27017
    * `db.response.status_code` - the server's error code, when the command failed
    * `error.type` - the error code, or the error's module when it has no code
    * `db.query.text` - the command, only when the `:db_query_text` option asks for it

  Spans are named `{db.operation.name} {target}`, where the target is the collection, or the
  database when the command names no collection.

  ## Metrics

  `db.client.operation.duration` is a histogram in seconds, recorded through
  `opentelemetry_api_experimental` with the attributes above except `db.query.text`.
  """

  require OpenTelemetryAPIExperimental.Histogram, as: Histogram

  alias OpenTelemetry.SemConv.ErrorAttributes
  alias OpenTelemetry.SemConv.Incubating.DBAttributes
  alias OpenTelemetry.SemConv.Incubating.Metrics.DBMetrics
  alias OpenTelemetry.SemConv.ServerAttributes

  require OpenTelemetry.Tracer
  require Logger

  @events [
    [:mongodb_driver, :command, :start],
    [:mongodb_driver, :command, :stop],
    [:mongodb_driver, :command, :exception]
  ]

  @metric_attributes [
    :"db.system.name",
    DBAttributes.db_namespace(),
    DBAttributes.db_collection_name(),
    DBAttributes.db_operation_name(),
    ServerAttributes.server_address(),
    ServerAttributes.server_port(),
    :"db.response.status_code",
    ErrorAttributes.error_type()
  ]

  @options_schema NimbleOptions.new!(
                    db_query_text: [
                      type: {:or, [{:in, [:disabled, :plain, :obfuscated]}, {:fun, 1}]},
                      default: :disabled,
                      doc: """
                      Whether to record the command as `db.query.text`:

                        * `:disabled` - leave it out
                        * `:obfuscated` - record it with every value replaced by `?`
                        * `:plain` - record it as it is, values included

                      A function can be given instead: it takes the command as a keyword list
                      and returns the string to record, or `nil` to leave it out.
                      """
                    ]
                  )

  @typedoc "Setup options"
  @type opts() :: unquote(NimbleOptions.option_typespec(@options_schema))

  @doc """
  Attaches the telemetry handler.

  ## Options

  #{NimbleOptions.docs(@options_schema)}
  """
  @spec setup(opts()) :: :ok
  def setup(opts \\ []) do
    config = Map.new(NimbleOptions.validate!(opts, @options_schema))

    unless :otel_telemetry_spans.started() do
      raise "the :opentelemetry_telemetry application must be started before OpentelemetryMongodbDriver.setup/1"
    end

    Histogram.create(DBMetrics.db_client_operation_duration(), %{
      unit: :s,
      description: "Duration of database client operations.",
      advisory_params: %{
        explicit_bucket_boundaries: [
          0.001,
          0.0025,
          0.005,
          0.01,
          0.025,
          0.05,
          0.1,
          0.25,
          0.5,
          1,
          2.5,
          5,
          10
        ]
      }
    })

    _ = :telemetry.attach_many(__MODULE__, @events, &__MODULE__.handle_event/4, config)

    :ok
  end

  @doc false
  def handle_event(event, measurements, metadata, config) do
    handle(event, measurements, metadata, config)
  rescue
    error ->
      Logger.error(
        "#{inspect(__MODULE__)} failed: " <> Exception.format(:error, error, __STACKTRACE__)
      )
  catch
    kind, reason ->
      Logger.error(
        "#{inspect(__MODULE__)} failed: " <> Exception.format(kind, reason, __STACKTRACE__)
      )
  end

  defp handle([:mongodb_driver, :command, :start], _measurements, metadata, config) do
    attributes =
      %{
        :"db.system.name" => :mongodb,
        unquote(DBAttributes.db_operation_name()) => to_string(metadata.command)
      }
      |> maybe_put(DBAttributes.db_namespace(), metadata.database)
      |> maybe_put(DBAttributes.db_collection_name(), metadata.collection)

    span =
      OpenTelemetry.Tracer.start_span(parent_context(metadata.caller), span_name(attributes), %{
        kind: :client,
        attributes:
          maybe_put(attributes, DBAttributes.db_query_text(), query_text(metadata, config))
      })

    :otel_telemetry_spans.put(metadata.telemetry_span_context, span, attributes) ||
      OpenTelemetry.Span.end_span(span)
  end

  defp handle([:mongodb_driver, :command, :stop], %{duration: duration}, metadata, _config) do
    with {span, attributes} <- :otel_telemetry_spans.take(metadata.telemetry_span_context) do
      attributes =
        attributes
        |> maybe_put(DBAttributes.db_namespace(), metadata.database)
        |> Map.merge(server_attributes(metadata.address))

      error = metadata.error
      status_code = status_code(error)

      error_attributes =
        %{}
        |> maybe_put(:"db.response.status_code", status_code)
        |> maybe_put(ErrorAttributes.error_type(), error_type(error, status_code))

      OpenTelemetry.Span.set_attributes(span, attributes)
      OpenTelemetry.Span.update_name(span, span_name(attributes))
      finish(span, attributes, error_attributes, duration)
    end
  end

  defp handle([:mongodb_driver, :command, :exception], %{duration: duration}, metadata, _config) do
    with {span, attributes} <- :otel_telemetry_spans.take(metadata.telemetry_span_context) do
      %{kind: kind, reason: reason, stacktrace: stacktrace} = metadata
      exception = Exception.normalize(kind, reason, stacktrace)

      if is_exception(exception) do
        OpenTelemetry.Span.record_exception(span, exception, stacktrace)
      end

      finish(
        span,
        attributes,
        %{ErrorAttributes.error_type() => error_type(exception, nil)},
        duration
      )
    end
  end

  defp finish(span, attributes, error_attributes, duration) do
    if error_type = error_attributes[ErrorAttributes.error_type()] do
      OpenTelemetry.Span.set_attributes(span, error_attributes)
      OpenTelemetry.Span.set_status(span, OpenTelemetry.status(:error, error_type))
    end

    OpenTelemetry.Span.end_span(span)

    Histogram.record(
      DBMetrics.db_client_operation_duration(),
      System.convert_time_unit(duration, :native, :nanosecond) / 1_000_000_000,
      attributes |> Map.merge(error_attributes) |> Map.take(@metric_attributes)
    )
  end

  defp parent_context(caller) when caller == self() do
    ctx = OpenTelemetry.Ctx.get_current()

    case OpenTelemetry.Tracer.current_span_ctx(ctx) do
      :undefined ->
        with :undefined <- OpentelemetryProcessPropagator.fetch_parent_ctx(1, :"$callers"),
             do: ctx

      _span ->
        ctx
    end
  end

  defp parent_context(caller) do
    with :undefined <- OpentelemetryProcessPropagator.fetch_ctx(caller),
         do: OpenTelemetry.Ctx.get_current()
  end

  defp span_name(attributes) do
    target =
      attributes[DBAttributes.db_collection_name()] || attributes[DBAttributes.db_namespace()]

    Enum.join(Enum.reject([attributes[DBAttributes.db_operation_name()], target], &is_nil/1), " ")
  end

  defp server_attributes(nil), do: %{}

  defp server_attributes(address) do
    case String.split(address, ":") do
      [host, port] ->
        maybe_put(
          %{ServerAttributes.server_address() => host},
          ServerAttributes.server_port(),
          server_port(port)
        )

      _path ->
        %{ServerAttributes.server_address() => address}
    end
  end

  defp server_port("27017"), do: nil
  defp server_port(port), do: String.to_integer(port)

  defp status_code(%{__struct__: Mongo.Error, code: code}) when is_integer(code),
    do: Integer.to_string(code)

  defp status_code(%{__struct__: Mongo.WriteError, write_errors: [%{"code" => code} | _]})
       when is_integer(code),
       do: Integer.to_string(code)

  defp status_code(_error), do: nil

  defp error_type(nil, _status_code), do: nil
  defp error_type(_error, status_code) when is_binary(status_code), do: status_code
  defp error_type(%module{}, nil), do: inspect(module)
  defp error_type(_error, nil), do: "_OTHER"

  defp query_text(_metadata, %{db_query_text: :disabled}), do: nil

  defp query_text(metadata, config) do
    command_text([{metadata.command, metadata.collection} | metadata.params], config)
  rescue
    _error -> nil
  end

  defp command_text(command, %{db_query_text: fun}) when is_function(fun, 1), do: fun.(command)

  defp command_text(command, %{db_query_text: :plain}),
    do: Jason.encode!(encodable(command, &plain/1))

  defp command_text(command, %{db_query_text: :obfuscated}),
    do: Jason.encode!(encodable(command, fn _ -> "?" end))

  defp encodable(value, leaf) when is_map(value) and not is_struct(value),
    do: Map.new(value, fn {key, item} -> {key, encodable(item, leaf)} end)

  defp encodable([{key, _} | _] = value, leaf) when is_atom(key) or is_binary(key),
    do: Map.new(value, fn {key, item} -> {key, encodable(item, leaf)} end)

  defp encodable(value, leaf) when is_list(value), do: Enum.map(value, &encodable(&1, leaf))
  defp encodable(value, leaf), do: leaf.(value)

  defp plain(value) when is_struct(value) or is_tuple(value) do
    if String.Chars.impl_for(value), do: to_string(value), else: inspect(value)
  end

  defp plain(value), do: value

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
