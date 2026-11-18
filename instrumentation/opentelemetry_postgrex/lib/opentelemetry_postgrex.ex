defmodule OpentelemetryPostgrex do
  @moduledoc """
  Traces [Postgrex](https://hex.pm/packages/postgrex) PostgreSQL queries with OpenTelemetry.

  Every query the driver reports on its `[:postgrex, :query, :start | :stop | :exception]`
  telemetry events becomes a `CLIENT` span and a `db.client.operation.duration` measurement.
  That covers `Postgrex.query/4`, streams (a span for each round trip), `COPY`, transactions and
  every query Ecto makes. The events fire in the process that runs the query, so the span is a
  child of that process's current span, or, in a task with no span of its own, of its caller's.

  ## Usage

  In your application start:

      def start(_type, _args) do
        OpentelemetryPostgrex.setup()

        # ...
      end

  ## Attributes

  Spans follow the [database client semantic conventions](https://opentelemetry.io/docs/specs/semconv/database/database-spans/)
  and the [PostgreSQL conventions](https://opentelemetry.io/docs/specs/semconv/database/postgresql/):

    * `db.system.name` - `postgresql`
    * `db.namespace` - the database
    * `db.collection.name` - the table, from the query's `:source` option, which Ecto sets; left
      out when the statement names more than one table
    * `db.query.summary` - each operation of the statement followed by the tables it names, such
      as `SELECT users` or `INSERT orders SELECT carts`
    * `db.query.text` - the statement, as the `:db_query_text` option says
    * `server.address` and `server.port` - the server; the port is left out when it is 5432,
      and a Unix socket is reported by its path
    * `db.response.returned_rows` - the rows the server returned; left out for a statement that
      returns none, such as an `INSERT` without `RETURNING`
    * `db.response.status_code` - the SQLSTATE code, when the query failed with one
    * `error.type` - the SQLSTATE code, or the error's module when it has no code

  Spans are named after `db.query.summary`, or, for a statement with no operation it knows, the
  table or the database.

  ## Metrics

  `db.client.operation.duration` is a histogram in seconds, recorded through
  `opentelemetry_api_experimental` with the attributes above except `db.query.text` and
  `db.response.returned_rows`.
  """

  alias OpenTelemetry.SemConv.ErrorAttributes
  alias OpenTelemetry.SemConv.Incubating.DBAttributes
  alias OpenTelemetry.SemConv.ServerAttributes

  @events [
    [:postgrex, :query, :start],
    [:postgrex, :query, :stop],
    [:postgrex, :query, :exception]
  ]
  @default_port 5432

  @options_schema NimbleOptions.new!(
                    db_query_text: [
                      type: {:in, [:disabled, :obfuscated, :plain]},
                      default: :obfuscated,
                      doc: """
                      Whether to record the statement as `db.query.text`:

                        * `:disabled` - leave it out
                        * `:obfuscated` - record it with every literal replaced by `?`; query
                          parameters, such as the ones Ecto sends, stay as they are
                        * `:plain` - record it as it is

                      Recorded text is cut to its first 2048 bytes.
                      """
                    ]
                  )

  @typedoc "Setup options"
  @type opts() :: unquote(NimbleOptions.option_typespec(@options_schema))

  @doc """
  Attaches the telemetry handlers.

  The `:opentelemetry_telemetry` application must be started first.

  ## Options

  #{NimbleOptions.docs(@options_schema)}
  """
  @spec setup(opts()) :: :ok
  def setup(opts \\ []) do
    :otel_db_client.attach(
      __MODULE__,
      @events,
      Map.new(NimbleOptions.validate!(opts, @options_schema))
    )
  end

  @doc false
  def handle([:postgrex, :query, :start], _measurements, metadata, %{db_query_text: mode}) do
    {statement_attributes, span_attributes} =
      case statement_text(metadata.query.statement) do
        nil -> {%{}, %{}}
        statement -> :otel_db_query_text.attributes(statement, metadata.source, mode)
      end

    :otel_db_client.start(
      __MODULE__,
      metadata.telemetry_span_context,
      Map.merge(connection_attributes(metadata), statement_attributes),
      span_attributes
    )
  end

  def handle([:postgrex, :query, :stop], %{duration: duration}, metadata, _config) do
    :otel_db_client.stop(metadata.telemetry_span_context, duration, fn _span ->
      {error_attributes(metadata.error),
       maybe_put(%{}, :"db.response.returned_rows", metadata.returned_rows)}
    end)
  end

  def handle([:postgrex, :query, :exception], %{duration: duration}, metadata, _config) do
    :otel_db_client.stop(metadata.telemetry_span_context, duration, fn span ->
      %{kind: kind, reason: reason, stacktrace: stacktrace} = metadata
      exception = Exception.normalize(kind, reason, stacktrace)

      if is_exception(exception) do
        OpenTelemetry.Span.record_exception(span, exception, stacktrace)
      end

      {error_attributes(exception), %{}}
    end)
  end

  defp connection_attributes(metadata) do
    %{:"db.system.name" => :postgresql}
    |> maybe_put(DBAttributes.db_namespace(), metadata.database)
    |> maybe_put(ServerAttributes.server_address(), server_address(metadata.hostname))
    |> maybe_put(ServerAttributes.server_port(), server_port(metadata.port))
  end

  defp statement_text(statement) do
    IO.iodata_to_binary(statement)
  rescue
    ArgumentError -> chardata_text(statement)
  end

  defp chardata_text(statement) do
    IO.chardata_to_string(statement)
  rescue
    _error -> nil
  end

  defp server_address({:local, path}), do: path
  defp server_address(hostname), do: hostname

  defp server_port(@default_port), do: nil
  defp server_port(port), do: port

  defp error_attributes(nil), do: %{}

  defp error_attributes(%{__struct__: Postgrex.Error, postgres: %{pg_code: code}})
       when is_binary(code),
       do: %{:"db.response.status_code" => code, ErrorAttributes.error_type() => code}

  defp error_attributes(%module{}), do: %{ErrorAttributes.error_type() => inspect(module)}
  defp error_attributes(_error), do: %{ErrorAttributes.error_type() => "_OTHER"}

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
