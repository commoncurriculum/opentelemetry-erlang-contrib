defmodule OpentelemetryPhoenix.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    Supervisor.start_link([OpentelemetryPhoenix.ChannelMetrics],
      strategy: :one_for_one,
      name: __MODULE__
    )
  end
end
