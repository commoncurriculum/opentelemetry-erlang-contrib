defmodule OpentelemetryDBConnection do
  @moduledoc """
  Records [DBConnection](https://hex.pm/packages/db_connection) pool timings with OpenTelemetry.

  Every driver built on DBConnection checks connections out of its pool and back in. This
  library turns DBConnection's `[:db_connection, :checkout]` and `[:db_connection, :checkin]`
  telemetry events into the
  [database client connection metrics](https://opentelemetry.io/docs/specs/semconv/database/database-metrics/#connection-pools),
  for every operation on every pool, whether it comes from Ecto or from the driver directly.

  The events are emitted in the process that holds the connection, so they need a
  DBConnection that emits them.

  ## Usage

  In your application start:

      def start(_type, _args) do
        OpentelemetryDBConnection.setup()

        # ...
      end

  ## Metrics

  Histograms in seconds, recorded through `opentelemetry_api_experimental`:

    * `db.client.connection.wait_time` - how long a caller waited for the pool to give it a
      connection
    * `db.client.connection.use_time` - how long the caller held the connection

  ## Attributes

    * `db.client.connection.pool.name` - the pool's `:label` start option (Ecto sets it to the
      repo), or the connection module when the pool has no label
    * `db.system.name` - the database, from the driver's connection module: `postgresql` for
      `Postgrex.Protocol`, `clickhouse` for `Ch.Connection`, `mongodb` for
      `Mongo.MongoDBConnection`, `mysql` for `MyXQL.Connection`, `microsoft.sql_server` for
      `Tds.Protocol` and `sqlite` for `Exqlite.Connection`; left out for any other driver
  """

  require OpenTelemetryAPIExperimental.Histogram, as: Histogram

  alias OpenTelemetry.SemConv.Incubating.DBAttributes
  alias OpenTelemetry.SemConv.Incubating.Metrics.DBMetrics

  @events [[:db_connection, :checkout], [:db_connection, :checkin]]

  @boundaries [0.001, 0.005, 0.01, 0.05, 0.1, 0.5, 1, 5, 10]

  @db_system_names %{
    Postgrex.Protocol => :postgresql,
    Ch.Connection => :clickhouse,
    Mongo.MongoDBConnection => :mongodb,
    MyXQL.Connection => :mysql,
    Tds.Protocol => :"microsoft.sql_server",
    Exqlite.Connection => :sqlite
  }

  @doc """
  Creates the histograms and attaches the telemetry handlers.
  """
  @spec setup() :: :ok
  def setup do
    Histogram.create(DBMetrics.db_client_connection_wait_time(), %{
      unit: :s,
      description: "The time it took to obtain an open connection from the pool.",
      advisory_params: %{explicit_bucket_boundaries: @boundaries}
    })

    Histogram.create(DBMetrics.db_client_connection_use_time(), %{
      unit: :s,
      description: "The time between borrowing a connection and returning it to the pool.",
      advisory_params: %{explicit_bucket_boundaries: @boundaries}
    })

    _ = :telemetry.attach_many(__MODULE__, @events, &__MODULE__.handle_event/4, nil)

    :ok
  end

  @doc false
  def handle_event([:db_connection, :checkout], %{wait_time: wait_time}, metadata, _config),
    do: record(DBMetrics.db_client_connection_wait_time(), wait_time, metadata)

  def handle_event([:db_connection, :checkin], %{use_time: use_time}, metadata, _config),
    do: record(DBMetrics.db_client_connection_use_time(), use_time, metadata)

  defp record(metric, native_time, %{label: label, connection_module: module}) do
    attributes = %{DBAttributes.db_client_connection_pool_name() => pool_name(label || module)}

    attributes =
      case @db_system_names do
        %{^module => system} -> Map.put(attributes, :"db.system.name", system)
        _ -> attributes
      end

    seconds = System.convert_time_unit(native_time, :native, :nanosecond) / 1_000_000_000
    Histogram.record(metric, seconds, attributes)
  end

  defp pool_name(name) when is_binary(name), do: name
  defp pool_name(name), do: inspect(name)
end
