# Changelog

## Unreleased

### Bug Fixes

* `setup/1` can now be called once per endpoint. The endpoint handler was
  attached under an id that did not vary with `:endpoint_prefix`, so
  applications running more than one endpoint silently lost the spans for
  every endpoint after the first. Reported in #537.

### Features

* Channel spans. `use OpentelemetryPhoenix.Channel` in a channel emits
  `[:phoenix, :channel, :join | :handle_in, :start | :stop | :exception]` telemetry around
  `join/3` and `handle_in/3`, and `setup/1` turns them into `JOIN MyAppWeb.RoomChannel` and
  `HANDLE_IN MyAppWeb.RoomChannel#event` server spans that parent the callback's work, with
  `phoenix.socket`, `phoenix.channel` and `phoenix.channel.event`. Phoenix itself only reports
  these callbacks after they return. A failed callback sets `error.type` and stays the current
  span, since the channel process crashes next and its crash report can then link to the trace.
  The `around: {module, function}` option runs application code around every `join/3` and
  `handle_in/3`, inside its span, and every `handle_info/2`. Turn the spans off with
  `channel: false`. Addresses open-telemetry/opentelemetry-erlang-contrib#314.
  The `carrier: {module, function}` option lets a channel continue a trace its messages
  carry: the function returns the text map a payload or `handle_info/2` message holds, and the
  global propagator reads it.

* Added `OpentelemetryPhoenix.LiveView.assign_async/4` and `start_async/4`, which carry the
  caller's OpenTelemetry context into the async task (from
  open-telemetry/opentelemetry-erlang-contrib#439). `phoenix`, `phoenix_html` and
  `phoenix_live_view` are now optional dependencies instead of dev/test-only ones.
* LiveView `handle_event` spans now carry `http.route`. The route resolved during
  `mount`/`handle_params` is kept for the lifetime of the LiveView process, since
  `handle_event` telemetry metadata carries no URI and the socket keeps no path.
* Added the `liveview_span_names` option. It defaults to `:module`, which keeps the
  existing `MyAppWeb.ResourceLive.mount` names. Setting it to `:route` opts into
  `{operation} {route}` names, such as `live_view.mount /resources/:resource_id` and
  `live_view.handle_event /resources/:resource_id hello`, matching how span names are
  built elsewhere in the Semantic Conventions. The module name is used as the fallback
  when a LiveView is not mounted at the router.
* Records the `http.server.request.duration` histogram (seconds, with the Semantic
  Conventions' advisory buckets) for every request through the endpoint's
  `Plug.Telemetry`, including requests whose exception Phoenix renders. Attributes:
  `http.request.method`, `url.scheme`, `http.response.status_code`, `http.route`,
  `network.protocol.version`, and `error.type` for 5xx. Adds a dependency on
  `opentelemetry_api_experimental`; recording is a no-op unless the
  `opentelemetry_experimental` SDK is running.
* Records channel metrics: `phoenix.channel.count` and `phoenix.socket.connection.count`
  (observable up-down counters of joined channels and the socket connections carrying
  them, by `phoenix.socket` and `phoenix.channel`), and the
  `phoenix.channel.handle_in.duration` histogram (seconds, by `phoenix.socket`,
  `phoenix.channel` and `phoenix.channel.event`). The library now has an application,
  which supervises the `Registry` that tracks joined channels.

## 2.0.0

### Features

- Added Bandit instrumentation support
- Semantic Conventions v1.27 support

### Breaking Changes

- Specifying an adapter is now required. Simply add the instrumentation
  library as a dep and follow its setup instructions, then specify your
  your adapter.
- Various HTTP Semantic Convention changes are included in the cowboy
  and bandit libraries. One major change regards span naming. This may
  affect your observability tools when keying on span names. The key
  change there is the HTTP method is now a prefix, e.g. "GET /users/:user_id"
- OpenTelemetry API v1.4 required

## 2.0.0-rc.1

### Features

- Added Bandit instrumentation support
- Semantic Conventions v1.27 support

### Breaking Changes

- Specifying an adapter is now required. Simply add the instrumentation
  library as a dep and follow its setup instructions, then specify your
  your adapter.
- Various HTTP Semantic Convention changes are included in the cowboy
  and bandit libraries. One major change regards span naming. This may
  affect your observability tools when keying on span names. The key
  change there is the HTTP method is now a prefix, e.g. "GET /users/:user_id"
- OpenTelemetry API v1.4 required

## 1.2.0

### Features

- Add support for LiveView courtesy of @derekkraan

### Fixes

- Do not set a span as errored for exceptions, only based on 5xx HTTP status

### Changed

- Minimum supported Elixir version changed to 1.11.

## 1.1.1

### Fixes

- [Relax nimble_options
  requirement](https://github.com/open-telemetry/opentelemetry-erlang-contrib/pull/161)

## 1.1.0

### Features

- Add support for opentelemetry_cowboy to capture the full request lifecycle
  when using the Plug.Cowboy adapter

## 1.0.0

### Fixes

- Prevent attempting to record an exception when no active span present
- Only mark 5xx level status codes as errored

## 1.0.0-rc.7

### Changed

- Opentelemetry 1.0 support

## 1.0.0-rc.6

### Changed

- Opentelemetry 1.0.0-rc.4 support

### Fixes

- pass attributes on span start for better sampling options
- fix http status attribute to match spec

## 1.0.0-rc.4

### Changed

- Opentelemetry dependency is locked to rc2 or lower in prep for breaking changes in rc3

## 1.0.0-rc.3

### Changed

- Update dependencies to allow telemetry 1.0.0

## 0.2.0

### Changed

- Upgraded to Opentelemetry v0.5.0
