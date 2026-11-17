defmodule OpentelemetryCh do
  @moduledoc """
  Traces [ch](https://hex.pm/packages/ch) ClickHouse queries with OpenTelemetry.

  Every query the driver reports on its `[:ch, :query, :start | :stop | :exception]` telemetry
  events becomes a `CLIENT` span and a `db.client.operation.duration` measurement. That covers
  `Ch.query/4`, `Ch.stream/4` and every query `ecto_ch` makes. The events fire in the process
  that runs the query, so the span is a child of that process's current span, or, in a task with
  no span of its own, of its caller's.

  ## Usage

  In your application start:

      def start(_type, _args) do
        OpentelemetryCh.setup()

        # ...
      end

  ## Attributes

  Spans follow the [database client semantic conventions](https://opentelemetry.io/docs/specs/semconv/database/database-spans/):

    * `db.system.name` - `clickhouse`
    * `db.namespace` - the database
    * `db.collection.name` - the table, from the query's `:source` option, which Ecto sets
    * `db.operation.name` - the statement's command, such as `SELECT` or `INSERT`
    * `db.query.text` - the statement, unless the `:db_query_text` option is `false`
    * `server.address` and `server.port` - the server; the port is left out when it is 8123
    * `db.response.returned_rows` - the rows a read returned, when ch reports them
    * `db.response.status_code` - the ClickHouse error code, when the query failed with one
    * `error.type` - the ClickHouse error code, or the error's module when it has no code

  Spans are named `{db.operation.name} {target}`, where the target is the table, or the database
  when the query names no table.

  ## Metrics

  `db.client.operation.duration` is a histogram in seconds, recorded through
  `opentelemetry_api_experimental` with the attributes above except `db.query.text`.
  """

  require OpenTelemetryAPIExperimental.Histogram, as: Histogram
  require OpenTelemetry.Tracer

  alias OpenTelemetry.SemConv.ErrorAttributes
  alias OpenTelemetry.SemConv.Incubating.DBAttributes
  alias OpenTelemetry.SemConv.Incubating.Metrics.DBMetrics
  alias OpenTelemetry.SemConv.ServerAttributes

  @events [[:ch, :query, :start], [:ch, :query, :stop], [:ch, :query, :exception]]
  @default_port 8123

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
                      type: :boolean,
                      default: true,
                      doc: """
                      Whether to record the statement as `db.query.text`. Statements sent with
                      query parameters, as Ecto's are, carry no values.
                      """
                    ]
                  )

  @typedoc "Setup options"
  @type opts() :: unquote(NimbleOptions.option_typespec(@options_schema))

  @doc """
  Attaches the telemetry handlers.

  ## Options

  #{NimbleOptions.docs(@options_schema)}
  """
  @spec setup(opts()) :: :ok
  def setup(opts \\ []) do
    config = Map.new(NimbleOptions.validate!(opts, @options_schema))

    unless OpentelemetryCh.Spans.started?() do
      raise "the :opentelemetry_ch application must be started before OpentelemetryCh.setup/1"
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
  def handle_event([:ch, :query, :start], _measurements, metadata, config) do
    attributes = attributes(metadata)

    span =
      OpenTelemetry.Tracer.start_span(parent_context(), span_name(attributes), %{
        kind: :client,
        attributes:
          maybe_put(attributes, DBAttributes.db_query_text(), query_text(metadata, config))
      })

    OpentelemetryCh.Spans.put(metadata.telemetry_span_context, span, attributes)
  end

  def handle_event([:ch, :query, :stop], %{duration: duration}, metadata, _config) do
    with {span, attributes} <- OpentelemetryCh.Spans.take(metadata.telemetry_span_context) do
      error = metadata.error
      status_code = status_code(error)

      error_attributes =
        %{}
        |> maybe_put(:"db.response.status_code", status_code)
        |> maybe_put(ErrorAttributes.error_type(), error_type(error, status_code))

      OpenTelemetry.Span.set_attributes(span, response_attributes(metadata))
      finish(span, attributes, error_attributes, duration)
    end
  end

  def handle_event([:ch, :query, :exception], %{duration: duration}, metadata, _config) do
    with {span, attributes} <- OpentelemetryCh.Spans.take(metadata.telemetry_span_context) do
      %{kind: kind, reason: reason, stacktrace: stacktrace} = metadata
      exception = Exception.normalize(kind, reason, stacktrace)

      if is_exception(exception) do
        OpenTelemetry.Span.record_exception(span, exception, stacktrace)
      end

      error_attributes = %{ErrorAttributes.error_type() => error_type(exception, nil)}
      finish(span, attributes, error_attributes, duration)
    end
  end

  defp finish(span, attributes, error_attributes, duration) do
    Histogram.record(
      DBMetrics.db_client_operation_duration(),
      System.convert_time_unit(duration, :native, :nanosecond) / 1_000_000_000,
      attributes |> Map.merge(error_attributes) |> Map.take(@metric_attributes)
    )

    if error_type = error_attributes[ErrorAttributes.error_type()] do
      OpenTelemetry.Span.set_attributes(span, error_attributes)
      OpenTelemetry.Span.set_status(span, OpenTelemetry.status(:error, error_type))
    end

    OpenTelemetry.Span.end_span(span)
  end

  defp attributes(metadata) do
    %{:"db.system.name" => :clickhouse}
    |> maybe_put(DBAttributes.db_namespace(), metadata.database)
    |> maybe_put(DBAttributes.db_collection_name(), metadata.source)
    |> maybe_put(DBAttributes.db_operation_name(), operation(metadata.query))
    |> maybe_put(ServerAttributes.server_address(), metadata.hostname)
    |> maybe_put(ServerAttributes.server_port(), server_port(metadata.port))
  end

  defp response_attributes(%{query: %{command: :insert}}), do: %{}

  defp response_attributes(metadata),
    do: maybe_put(%{}, :"db.response.returned_rows", Map.get(metadata, :num_rows))

  defp parent_context do
    with :undefined <- OpentelemetryProcessPropagator.fetch_ctx(self()),
         :undefined <- OpentelemetryProcessPropagator.fetch_parent_ctx(1, :"$callers") do
      OpenTelemetry.Ctx.get_current()
    end
  end

  defp operation(%{command: command}) when is_atom(command) and not is_nil(command),
    do: command |> Atom.to_string() |> String.upcase()

  defp operation(_query), do: nil

  defp span_name(attributes) do
    target =
      attributes[DBAttributes.db_collection_name()] || attributes[DBAttributes.db_namespace()]

    case Enum.reject([attributes[DBAttributes.db_operation_name()], target], &is_nil/1) do
      [] -> "clickhouse"
      parts -> Enum.join(parts, " ")
    end
  end

  defp server_port(@default_port), do: nil
  defp server_port(port), do: port

  defp query_text(_metadata, %{db_query_text: false}), do: nil
  defp query_text(%{query: %{statement: statement}}, _config), do: IO.iodata_to_binary(statement)

  defp status_code(%{__struct__: Ch.Error, code: code}) when is_integer(code),
    do: Integer.to_string(code)

  defp status_code(_error), do: nil

  defp error_type(nil, _status_code), do: nil
  defp error_type(_error, status_code) when is_binary(status_code), do: status_code
  defp error_type(%module{}, nil), do: inspect(module)
  defp error_type(_error, nil), do: "_OTHER"

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
