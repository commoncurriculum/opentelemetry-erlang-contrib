# Changelog

## Unreleased

### Breaking Changes

* Spans come from the driver's `[:mongodb_driver, :execution]` event, in the process that ran
  the command, so they are children of that process's span (or, in a task, of its caller's
  span). The `EventMonitor` process and the application module are gone.
* Attributes follow the stable database semantic conventions: `db.system.name`,
  `db.namespace`, `db.collection.name`, `db.operation.name`, `db.response.status_code` and
  `error.type`. Spans are named `{db.operation.name} {db.collection.name}`.
* The `:db_statement` option is now `:db_query_text` and sets `db.query.text`.
* A failed span's status description is its error code, not the error message, which can
  hold the command's values.

### Features

* Record the `db.client.operation.duration` histogram.

## 0.1.1

### Bug fixes

* Report errors via OpenTelemetry SetStatus API instead of custom
  attributes

## 0.1.0

* Initial release
