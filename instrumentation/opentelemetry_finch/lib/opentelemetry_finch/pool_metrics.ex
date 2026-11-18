defmodule OpentelemetryFinch.PoolMetrics do
  @moduledoc false
  require OpenTelemetryAPIExperimental.ObservableUpDownCounter

  alias OpenTelemetry.SemConv.Incubating.HTTPAttributes
  alias OpenTelemetry.SemConv.Incubating.Metrics.HTTPMetrics
  alias OpenTelemetry.SemConv.ServerAttributes
  alias OpenTelemetry.SemConv.URLAttributes
  alias OpenTelemetryAPIExperimental.ObservableUpDownCounter

  def setup(opts) do
    ObservableUpDownCounter.create(
      HTTPMetrics.http_client_open_connections(),
      &__MODULE__.observe/1,
      {Keyword.fetch!(opts, :name), Keyword.fetch!(opts, :pools)},
      %{
        unit: :"{connection}",
        description:
          "Connections checked out of a Finch HTTP/1 pool. Finch starts connections lazily, so its available count is free slots, not idle connections."
      }
    )
  end

  def observe({name, pools}) do
    pools
    |> Enum.flat_map(&pool_status(name, &1))
    |> Enum.flat_map(fn
      {pool, [%Finch.HTTP1.PoolMetrics{} | _] = shards} ->
        [
          {shards |> Enum.map(& &1.in_use_connections) |> Enum.sum(),
           %{
             HTTPAttributes.http_connection_state() => :active,
             ServerAttributes.server_address() => pool.host,
             ServerAttributes.server_port() => pool.port,
             URLAttributes.url_scheme() => pool.scheme
           }}
        ]

      {_pool, _http2_shards} ->
        []
    end)
  end

  defp pool_status(name, :default) do
    case Finch.get_pool_status(name, :default) do
      {:ok, pools} -> Enum.to_list(pools)
      {:error, :not_found} -> []
    end
  end

  defp pool_status(name, url) do
    case Finch.get_pool_status(name, url) do
      {:ok, shards} -> [{Finch.Pool.new(url), shards}]
      {:error, :not_found} -> []
    end
  end
end
