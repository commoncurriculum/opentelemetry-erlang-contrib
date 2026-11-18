defmodule OpentelemetryDBConnection.Pools do
  @moduledoc false

  use GenServer

  alias OpenTelemetry.SemConv.Incubating.DBAttributes
  alias OpenTelemetry.SemConv.Incubating.Metrics.DBMetrics

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  def track(pool, attributes, pool_size),
    do: GenServer.cast(__MODULE__, {:track, pool, attributes, pool_size})

  def observe(_args) do
    pools =
      for {pool, attributes, pool_size} <- :ets.tab2list(__MODULE__),
          {:ok, idle, pending} <- [connection_metrics(pool)],
          reduce: %{} do
        acc ->
          Map.update(acc, attributes, {pool_size, idle, pending}, fn {max, i, p} ->
            {max + pool_size, i + idle, p + pending}
          end)
      end

    state = DBAttributes.db_client_connection_state()

    [
      {DBMetrics.db_client_connection_count(),
       Enum.flat_map(pools, fn {attributes, {max, idle, _pending}} ->
         [
           {idle, Map.put(attributes, state, :idle)},
           {max - idle, Map.put(attributes, state, :used)}
         ]
       end)},
      {DBMetrics.db_client_connection_max(),
       Enum.map(pools, fn {attributes, {max, _idle, _pending}} -> {max, attributes} end)},
      {DBMetrics.db_client_connection_pending_requests(),
       Enum.map(pools, fn {attributes, {_max, _idle, pending}} -> {pending, attributes} end)}
    ]
  end

  defp connection_metrics(pool) do
    [%{ready_conn_count: idle, checkout_queue_length: pending}] =
      DBConnection.ConnectionPool.get_connection_metrics(pool)

    {:ok, idle, pending}
  catch
    :exit, _reason -> :error
  end

  @impl GenServer
  def init(nil) do
    :ets.new(__MODULE__, [:named_table, :protected, read_concurrency: true])
    {:ok, nil}
  end

  @impl GenServer
  def handle_cast({:track, pool, attributes, pool_size}, state) do
    Process.monitor(pool)
    :ets.insert(__MODULE__, {pool, attributes, pool_size})
    {:noreply, state}
  end

  @impl GenServer
  def handle_info({:DOWN, _ref, :process, pool, _reason}, state) do
    :ets.delete(__MODULE__, pool)
    {:noreply, state}
  end
end
