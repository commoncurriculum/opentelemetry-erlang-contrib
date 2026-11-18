defmodule OpentelemetryDBConnection.Application do
  @moduledoc false

  use Application

  @impl Application
  def start(_type, _args) do
    Supervisor.start_link([OpentelemetryDBConnection.Pools],
      strategy: :one_for_one,
      name: OpentelemetryDBConnection.Supervisor
    )
  end
end
