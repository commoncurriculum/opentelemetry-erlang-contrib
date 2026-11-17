defmodule OpentelemetryCh.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    Supervisor.start_link([OpentelemetryCh.Spans], strategy: :one_for_one, name: __MODULE__)
  end
end
