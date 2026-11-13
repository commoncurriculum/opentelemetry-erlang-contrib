defmodule OpentelemetryMongodbDriver do
  @moduledoc """
  Traces [mongodb_driver](https://hex.pm/packages/mongodb_driver) commands with OpenTelemetry.

  Every command the driver reports on its `[:mongodb_driver, :execution]` telemetry event
  becomes a `CLIENT` span and a `db.client.operation.duration` measurement. The event fires in
  the process that ran the command, after the reply, so the span is a child of that process's
  current span and starts when the command started.

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
    * `db.response.status_code` - the server's error code, when the command failed
    * `error.type` - the error code, or the error's module when it has no code
    * `db.query.text` - the command, only when the `:db_query_text` option asks for it

  Spans are named `{db.operation.name} {db.collection.name}`, or `{db.operation.name}` when the
  command names no collection.

  The `database` and `error` values of the telemetry event, which fill `db.namespace`,
  `db.response.status_code` and `error.type`, need a driver release that includes them; with an
  older driver those attributes are left out.

  ## Metrics

  `db.client.operation.duration` is a histogram in seconds, recorded through
  `opentelemetry_api_experimental` with the attributes above except `db.query.text`.
  """

  require OpenTelemetryAPIExperimental.Histogram, as: Histogram

  alias OpenTelemetry.SemConv.ErrorAttributes
  alias OpenTelemetry.SemConv.Incubating.DBAttributes
  alias OpenTelemetry.SemConv.Incubating.Metrics.DBMetrics

  require OpenTelemetry.Tracer

  @event [:mongodb_driver, :execution]

  @metric_attributes [
    :"db.system.name",
    DBAttributes.db_namespace(),
    DBAttributes.db_collection_name(),
    DBAttributes.db_operation_name(),
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

    _ = :telemetry.attach({__MODULE__, :execution}, @event, &__MODULE__.handle_event/4, config)

    :ok
  end

  @doc false
  def handle_event(@event, %{duration: duration}, metadata, config) do
    end_time = :opentelemetry.timestamp()
    start_time = end_time - System.convert_time_unit(duration, :microsecond, :native)

    operation = to_string(metadata.command)
    collection = collection(metadata.collection)
    error = Map.get(metadata, :error)
    status_code = status_code(error)

    attributes =
      %{
        :"db.system.name" => :mongodb,
        unquote(DBAttributes.db_operation_name()) => operation
      }
      |> maybe_put(DBAttributes.db_namespace(), Map.get(metadata, :database))
      |> maybe_put(DBAttributes.db_collection_name(), collection)
      |> maybe_put(:"db.response.status_code", status_code)
      |> maybe_put(ErrorAttributes.error_type(), error_type(error, status_code))

    Histogram.record(
      DBMetrics.db_client_operation_duration(),
      duration / 1_000_000,
      Map.take(attributes, @metric_attributes)
    )

    attributes =
      maybe_put(
        attributes,
        DBAttributes.db_query_text(),
        query_text([{metadata.command, metadata.collection} | metadata.params], config)
      )

    parent_token =
      case parent_context() do
        :undefined -> :undefined
        ctx -> OpenTelemetry.Ctx.attach(ctx)
      end

    span =
      OpenTelemetry.Tracer.start_span(span_name(operation, collection), %{
        start_time: start_time,
        attributes: attributes,
        kind: :client
      })

    if error do
      OpenTelemetry.Span.set_status(
        span,
        OpenTelemetry.status(:error, attributes[ErrorAttributes.error_type()])
      )
    end

    OpenTelemetry.Span.end_span(span)

    if parent_token != :undefined do
      OpenTelemetry.Ctx.detach(parent_token)
    end

    :ok
  end

  defp parent_context do
    case OpentelemetryProcessPropagator.fetch_ctx(self()) do
      :undefined -> OpentelemetryProcessPropagator.fetch_parent_ctx(1, :"$callers")
      ctx -> ctx
    end
  end

  defp span_name(operation, nil), do: operation
  defp span_name(operation, collection), do: "#{operation} #{collection}"

  defp collection("-"), do: nil

  defp collection(collection) when is_binary(collection) do
    case Integer.parse(collection) do
      {_, ""} -> nil
      _ -> collection
    end
  end

  defp collection(_collection), do: nil

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

  defp query_text(_command, %{db_query_text: :disabled}), do: nil
  defp query_text(command, %{db_query_text: fun}) when is_function(fun, 1), do: fun.(command)

  defp query_text(command, %{db_query_text: :plain}),
    do: Jason.encode!(encodable(command, &plain/1))

  defp query_text(command, %{db_query_text: :obfuscated}),
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
