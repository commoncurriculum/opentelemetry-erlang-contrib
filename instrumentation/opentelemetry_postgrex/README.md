# OpentelemetryPostgrex

Traces [Postgrex](https://hex.pm/packages/postgrex) PostgreSQL queries with OpenTelemetry,
following the
[database client semantic conventions](https://opentelemetry.io/docs/specs/semconv/database/database-spans/).
Each query becomes a `CLIENT` span and a `db.client.operation.duration` measurement, whether it
comes from `Postgrex.query/4`, a stream, a transaction or Ecto.

It needs a Postgrex that emits `[:postgrex, :query, :start | :stop | :exception]` telemetry.

## Installation

```elixir
def deps do
  [
    {:opentelemetry_postgrex, "~> 0.1"}
  ]
end
```

## Usage

```elixir
def start(_type, _args) do
  OpentelemetryPostgrex.setup()

  # ...
end
```

See `OpentelemetryPostgrex.setup/1` for the options.

## Testing

The tests run against a real PostgreSQL on `localhost:5432` with user and password `postgres`
(`docker compose up -d`), or the one `POSTGRES_HOSTNAME` and `POSTGRES_PORT` name.
