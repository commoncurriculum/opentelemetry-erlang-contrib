# OpentelemetryCh

Traces [ch](https://hex.pm/packages/ch) ClickHouse queries with OpenTelemetry, following the
[database client semantic conventions](https://opentelemetry.io/docs/specs/semconv/database/database-spans/).
Each query becomes a `CLIENT` span and a `db.client.operation.duration` measurement, whether it
comes from `Ch.query/4`, `Ch.stream/4` or `ecto_ch`.

It needs a ch that emits `[:ch, :query, :start | :stop | :exception]` telemetry.

## Installation

```elixir
def deps do
  [
    {:opentelemetry_ch, "~> 0.1"}
  ]
end
```

## Usage

```elixir
def start(_type, _args) do
  OpentelemetryCh.setup()

  # ...
end
```

See `OpentelemetryCh.setup/1` for the options.

## Testing

The tests run against a real ClickHouse on `localhost:8123` (`docker compose up -d`), or the one
`CLICKHOUSE_HOSTNAME` and `CLICKHOUSE_PORT` name.
