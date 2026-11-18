defmodule OpentelemetryMongodbDriver do
  @moduledoc """
  Traces [mongodb_driver](https://hex.pm/packages/mongodb_driver) commands with OpenTelemetry.

  Every operation the driver reports on its `[:mongodb_driver, :command, :start | :stop |
  :exception]` telemetry events becomes a `CLIENT` span and a `db.client.operation.duration`
  measurement. An operation covers its retries and the server selection of each, so a retried
  write is one span, and a command that finds no server is a failed one. That covers network
  errors and timeouts as well as server errors. The span is a child of the current span of the
  process that ran the operation, or, in a task with no span of its own, of its caller's. A
  transaction's commit and abort, which the driver runs in the session process, are children of
  the current span of the process that committed or aborted.
  Requires the `:opentelemetry_telemetry` application, whose span store ends the span of a caller
  that exits mid-operation.

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
    * `server.address` and `server.port` - the first server the client is configured with; the
      port is left out when it is 27017
    * `network.peer.address` and `network.peer.port` - the server the last attempt reached, on
      the span only
    * `db.response.status_code` - the server's error code, when the command failed
    * `error.type` - the error code, or the error's module when it has no code
    * `db.query.text` - the command, as the `:db_query_text` option says, on the span only

  Spans are named `{db.operation.name} {target}`, where the target is the collection, or the
  database when the command names no collection.

  ## Metrics

  `db.client.operation.duration` is a histogram in seconds, recorded through
  `opentelemetry_api_experimental` with the attributes above except the span-only ones.
  """

  alias OpenTelemetry.SemConv.ErrorAttributes
  alias OpenTelemetry.SemConv.Incubating.DBAttributes
  alias OpenTelemetry.SemConv.ServerAttributes

  @events [
    [:mongodb_driver, :command, :start],
    [:mongodb_driver, :command, :stop],
    [:mongodb_driver, :command, :exception]
  ]

  @max_query_text_bytes 2048

  @options_schema NimbleOptions.new!(
                    db_query_text: [
                      type: {:in, [:disabled, :obfuscated, :plain]},
                      default: :obfuscated,
                      doc: """
                      Whether to record the command as `db.query.text`:

                        * `:disabled` - leave it out
                        * `:obfuscated` - record it with every key and its collection, and every
                          other value replaced by `?`
                        * `:plain` - record it as it is, values included

                      Recorded text is built only up to its first 2048 bytes.
                      """
                    ]
                  )

  @typedoc "Setup options"
  @type opts() :: unquote(NimbleOptions.option_typespec(@options_schema))

  @doc """
  Attaches the telemetry handler.

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
  def handle([:mongodb_driver, :command, :start], _measurements, metadata, config) do
    :otel_db_client.start(
      __MODULE__,
      metadata.telemetry_span_context,
      attributes(metadata),
      maybe_put(%{}, DBAttributes.db_query_text(), query_text(metadata, config)),
      metadata.caller
    )
  end

  def handle([:mongodb_driver, :command, :stop], %{duration: duration}, metadata, _config) do
    :otel_db_client.stop(metadata.telemetry_span_context, duration, fn _span ->
      {metadata.error
       |> error_attributes()
       |> maybe_put(DBAttributes.db_namespace(), metadata.database),
       peer_attributes(metadata.address)}
    end)
  end

  def handle([:mongodb_driver, :command, :exception], %{duration: duration}, metadata, _config) do
    :otel_db_client.stop(metadata.telemetry_span_context, duration, fn span ->
      %{kind: kind, reason: reason, stacktrace: stacktrace} = metadata
      exception = Exception.normalize(kind, reason, stacktrace)

      if is_exception(exception) do
        OpenTelemetry.Span.record_exception(span, exception, stacktrace)
      end

      {error_attributes(exception), %{}}
    end)
  end

  defp attributes(metadata) do
    %{
      :"db.system.name" => :mongodb,
      unquote(DBAttributes.db_operation_name()) => to_string(metadata.command)
    }
    |> maybe_put(DBAttributes.db_namespace(), metadata.database)
    |> maybe_put(DBAttributes.db_collection_name(), metadata.collection)
    |> Map.merge(server_attributes(metadata.servers))
  end

  defp server_attributes([server | _]) do
    {address, port} = host_port(server)

    maybe_put(
      %{ServerAttributes.server_address() => address},
      ServerAttributes.server_port(),
      port
    )
  end

  defp server_attributes([]), do: %{}

  defp peer_attributes(nil), do: %{}

  defp peer_attributes(peer) do
    {address, port} = host_port(peer)
    maybe_put(%{"network.peer.address": address}, :"network.peer.port", port)
  end

  defp host_port(server) do
    case String.split(server, ":") do
      [host, port] -> {host, port(port)}
      _path -> {server, nil}
    end
  end

  defp port("27017"), do: nil
  defp port(port), do: String.to_integer(port)

  defp error_attributes(nil), do: %{}

  defp error_attributes(error) do
    case status_code(error) do
      nil -> %{ErrorAttributes.error_type() => error_type(error)}
      code -> %{:"db.response.status_code" => code, ErrorAttributes.error_type() => code}
    end
  end

  defp status_code(%{__struct__: Mongo.Error, code: code}) when is_integer(code),
    do: Integer.to_string(code)

  defp status_code(%{__struct__: Mongo.WriteError, write_errors: [%{"code" => code} | _]})
       when is_integer(code),
       do: Integer.to_string(code)

  defp status_code(_error), do: nil

  defp error_type(%module{}), do: inspect(module)
  defp error_type(_error), do: "_OTHER"

  defp query_text(_metadata, %{db_query_text: :disabled}), do: nil

  defp query_text(%{cmd: cmd, collection: collection}, %{db_query_text: mode}) do
    {text, _budget} = object(cmd, {mode, collection}, @max_query_text_bytes)
    text |> IO.iodata_to_binary() |> :otel_db_query_text.truncate()
  rescue
    _error -> nil
  end

  defp json(_value, _mode, budget) when budget <= 0, do: {[], budget}

  defp json(value, {_mode, value} = mode, budget) when is_binary(value),
    do: leaf(value, mode, budget, :plain)

  defp json(value, mode, budget) when is_map(value) and not is_struct(value),
    do: object(Map.to_list(value), mode, budget)

  defp json([{key, _} | _] = value, mode, budget) when is_atom(key) or is_binary(key),
    do: object(value, mode, budget)

  defp json(value, mode, budget) when is_list(value), do: array(value, mode, budget)
  defp json(value, {mode, _collection} = context, budget), do: leaf(value, context, budget, mode)

  defp object(pairs, mode, budget) do
    {items, budget} =
      join(pairs, budget - 1, fn {key, value}, budget ->
        key = Jason.encode!(to_string(key)) <> ":"
        {value, budget} = json(value, mode, budget - byte_size(key))
        {[key | value], budget}
      end)

    {["{", items, "}"], budget - 1}
  end

  defp array(values, mode, budget) do
    {items, budget} = join(values, budget - 1, &json(&1, mode, &2))
    {["[", items, "]"], budget - 1}
  end

  defp join(values, budget, encode) do
    {items, budget} =
      Enum.reduce_while(values, {[], budget}, fn value, {items, budget} ->
        if budget <= 0 do
          {:halt, {items, budget}}
        else
          separator = if items == [], do: [], else: ","
          {item, budget} = encode.(value, budget - byte_size(IO.iodata_to_binary(separator)))
          {:cont, {[item, separator | items], budget}}
        end
      end)

    {Enum.reverse(items), budget}
  end

  defp leaf(_value, _context, budget, :obfuscated), do: {~s("?"), budget - 3}

  defp leaf(value, _context, budget, :plain) do
    text = Jason.encode!(plain(value))
    {text, budget - byte_size(text)}
  end

  defp plain(value) when is_struct(value) or is_tuple(value) do
    if String.Chars.impl_for(value), do: to_string(value), else: inspect(value)
  end

  defp plain(value), do: value

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
