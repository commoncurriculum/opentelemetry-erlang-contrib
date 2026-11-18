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
      connection, for callers that got one
    * `db.client.connection.use_time` - how long the caller held the connection

  A counter, `db.client.connection.timeouts`, of callers that timed out waiting in the
  pool's queue: dropped from the queue, or still queued when their deadline passed.

  And up-down counters read from every running pool each time metrics are collected, summed
  over the pools that share a name:

    * `db.client.connection.count` - connections ready in the pool (`db.client.connection.state`
      `idle`) and the rest of the pool's size (`used`)
    * `db.client.connection.max` - the pool's size
    * `db.client.connection.pending_requests` - callers queued for a connection

  A pool is found by the `[:db_connection, :pool, :init]` event it emits when it starts, so
  only pools started after `setup/0` are reported.

  ## Attributes

    * `db.client.connection.pool.name` - the pool's `:label` start option (Ecto sets it to the
      repo), or the connection module when the pool has no label
    * `db.system.name` - the database, from the driver's connection module: `postgresql` for
      `Postgrex.Protocol`, `clickhouse` for `Ch.Connection`, `mongodb` for
      `Mongo.MongoDBConnection`, `mysql` for `MyXQL.Connection`, `microsoft.sql_server` for
      `Tds.Protocol` and `sqlite` for `Exqlite.Connection`; left out for any other driver
  """

  require OpenTelemetryAPIExperimental.Counter, as: Counter
  require OpenTelemetryAPIExperimental.Histogram, as: Histogram
  require OpenTelemetryAPIExperimental.ObservableUpDownCounter, as: ObservableUpDownCounter
  require Logger

  alias OpenTelemetry.SemConv.Incubating.DBAttributes
  alias OpenTelemetry.SemConv.Incubating.Metrics.DBMetrics

  alias OpentelemetryDBConnection.Pools

  @events [
    [:db_connection, :checkout],
    [:db_connection, :checkin],
    [:db_connection, :pool, :init]
  ]

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
  Creates the instruments and attaches the telemetry handlers.
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

    Counter.create(DBMetrics.db_client_connection_timeouts(), %{
      unit: "{timeout}",
      description:
        "The number of connection timeouts that have occurred trying to obtain a connection from the pool."
    })

    pool_instruments = [
      ObservableUpDownCounter.create(DBMetrics.db_client_connection_count(), %{
        unit: "{connection}",
        description:
          "The number of connections that are currently in state described by the state attribute."
      }),
      ObservableUpDownCounter.create(DBMetrics.db_client_connection_max(), %{
        unit: "{connection}",
        description: "The maximum number of open connections allowed."
      }),
      ObservableUpDownCounter.create(DBMetrics.db_client_connection_pending_requests(), %{
        unit: "{request}",
        description: "The number of current pending requests for an open connection."
      })
    ]

    :ok =
      :otel_meter.register_callback(
        :opentelemetry_experimental.get_meter(:opentelemetry.get_application_scope(__MODULE__)),
        pool_instruments,
        &Pools.observe/1,
        nil
      )

    _ = :telemetry.attach_many(__MODULE__, @events, &__MODULE__.handle_event/4, nil)

    :ok
  end

  @doc false
  def handle_event(event, measurements, metadata, _config) do
    handle(event, measurements, metadata)
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

  defp handle([:db_connection, :checkout], _measurements, %{timed_out: true} = metadata),
    do: Counter.add(DBMetrics.db_client_connection_timeouts(), 1, attributes(metadata))

  defp handle([:db_connection, :checkout], _measurements, %{error: _}), do: :ok

  defp handle([:db_connection, :checkout], %{wait_time: wait_time}, metadata),
    do: record(DBMetrics.db_client_connection_wait_time(), wait_time, attributes(metadata))

  defp handle([:db_connection, :checkin], %{use_time: use_time}, metadata),
    do: record(DBMetrics.db_client_connection_use_time(), use_time, attributes(metadata))

  defp handle([:db_connection, :pool, :init], %{pool_size: pool_size}, %{pool: pool} = metadata),
    do: Pools.track(pool, attributes(metadata), pool_size)

  defp record(metric, native_time, attributes) do
    seconds = System.convert_time_unit(native_time, :native, :nanosecond) / 1_000_000_000
    Histogram.record(metric, seconds, attributes)
  end

  defp attributes(%{label: label, connection_module: module}) do
    attributes = %{DBAttributes.db_client_connection_pool_name() => pool_name(label || module)}

    case @db_system_names do
      %{^module => system} -> Map.put(attributes, :"db.system.name", system)
      _ -> attributes
    end
  end

  defp pool_name(name) when is_binary(name), do: name
  defp pool_name(name), do: inspect(name)
end
