# OpentelemetryMongodbDriver

Traces [mongodb_driver](https://hex.pm/packages/mongodb_driver) commands with OpenTelemetry,
following the [MongoDB semantic conventions](https://opentelemetry.io/docs/specs/semconv/database/mongodb/).
Each command becomes a `CLIENT` span and a `db.client.operation.duration` measurement.

## Installation

```elixir
def deps do
  [
    {:opentelemetry_mongodb_driver, "~> 0.2"}
  ]
end
```

## Usage

```elixir
def start(_type, _args) do
  OpentelemetryMongodbDriver.setup()

  # ...
end
```

See `OpentelemetryMongodbDriver.setup/1` for the options.

## Testing

The tests run against a real MongoDB on `localhost:27017` (`docker compose up -d`), or the one
`MONGODB_URL` names.

## Credits

This package started as [opentelemetry_mongodb_driver](https://hex.pm/packages/opentelemetry_mongodb_driver)
0.1, published by [andrewhr](https://hex.pm/users/andrewhr).
