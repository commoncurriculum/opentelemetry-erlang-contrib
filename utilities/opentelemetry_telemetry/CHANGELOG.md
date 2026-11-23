# Changelog

## Unreleased

### Features

* `otel_telemetry_spans` keeps spans whose start and stop events fire in different processes,
  and ends the spans of callers that exit before their stop.
* `otel_db_client` writes the operation in a span name in SCREAMING_SNAKE_CASE (`FIND_AND_MODIFY users`,
  `CREATE_TABLE users`); `db.operation.name` keeps the database's own spelling.

### Fixes

* `otel_db_client` parents a query on the nearest of `$callers` with a context, not only the first.
  A process that only relays work, such as the server Cachex 4.1 runs a fetch fallback under, no
  longer turns the query into a root span.

* Do not attempt to end a span with if the ctx is undefined.

## 1.0.0-beta.7

### Changes

* OpenTelemetry 1.0 support

## 1.0.0-beta.6

### Changes

* OpenTelemetry 1.0.0-rc.4 support

## 1.0.0-beta.4

### Changes

* OpenTelemetry 1.0.0-rc.3 support

## 1.0.0-beta.3

### Changes

* telemetry v1.0.0 required

## 1.0.0-beta.2

### Breaking Changes

* The internal ctx handling mechanisms have been removed from the public API and replaced with more meaningful span operation functions to provide better abstractions
