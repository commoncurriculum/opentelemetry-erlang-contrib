# OpentelemetryDBConnection

Records [DBConnection](https://hex.pm/packages/db_connection) pool timings with OpenTelemetry,
following the
[database client connection metrics](https://opentelemetry.io/docs/specs/semconv/database/database-metrics/#connection-pools):
`db.client.connection.wait_time` and `db.client.connection.use_time`, for every driver built on
DBConnection (Postgrex, ch, mongodb_driver, MyXQL and others), whether or not Ecto is in use.

It needs a DBConnection that emits `[:db_connection, :checkout | :checkin]` telemetry.

## Installation

```elixir
def deps do
  [
    {:opentelemetry_db_connection, "~> 0.1"}
  ]
end
```

## Usage

```elixir
def start(_type, _args) do
  OpentelemetryDBConnection.setup()

  # ...
end
```
