defmodule OpentelemetryEcto.ClickhouseTestRepo do
  use Ecto.Repo,
    otp_app: :opentelemetry_ecto,
    adapter: Ecto.Adapters.ClickHouse
end
