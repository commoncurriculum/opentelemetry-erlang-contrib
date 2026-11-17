defmodule OpentelemetryPostgrex.Spans do
  @moduledoc false

  # Open spans, keyed by the query's telemetry_span_context. A query's start and stop can come
  # from different processes: the pool's connection process stops the queries of a caller whose
  # checkout timed out. A span whose caller exits before its query stops is ended by the sweep.

  use GenServer

  require OpenTelemetry.Tracer

  alias OpenTelemetry.SemConv.ErrorAttributes

  @sweep_interval :timer.seconds(10)

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @spec put(reference, :opentelemetry.span_ctx(), map) :: true
  def put(ref, span, attributes), do: :ets.insert(__MODULE__, {ref, span, attributes, self()})

  @spec take(reference) :: {:opentelemetry.span_ctx(), map} | nil
  def take(ref) do
    case :ets.take(__MODULE__, ref) do
      [{^ref, span, attributes, _caller}] -> {span, attributes}
      [] -> nil
    end
  end

  @spec started?() :: boolean
  def started?, do: :ets.whereis(__MODULE__) != :undefined

  @impl true
  def init(nil) do
    :ets.new(__MODULE__, [:named_table, :public, :set, write_concurrency: true])
    schedule_sweep()
    {:ok, nil}
  end

  @impl true
  def handle_info(:sweep, state) do
    sweep()
    schedule_sweep()
    {:noreply, state}
  end

  @doc false
  def sweep do
    for {ref, _span, _attributes, caller} <- :ets.tab2list(__MODULE__),
        not Process.alive?(caller),
        [{^ref, span, _attributes, _caller}] <- [:ets.take(__MODULE__, ref)] do
      OpenTelemetry.Span.set_attributes(span, %{ErrorAttributes.error_type() => "_OTHER"})
      OpenTelemetry.Span.set_status(span, OpenTelemetry.status(:error, "caller exited"))
      OpenTelemetry.Span.end_span(span)
    end

    :ok
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval)
end
