# Changelog

## Unreleased

* `require_parent_span: true` records no span for a query outside a trace, such as a job queue's
  polling; its `db.client.operation.duration` is still recorded. A query in a process that
  relays for a traced caller, such as a Cachex fetch fallback, is a child of that caller's span.

* Open spans are kept in `opentelemetry_telemetry`'s shared span store.

* Spans and `db.client.operation.duration` for every query Postgrex reports on its
  `[:postgrex, :query, ...]` telemetry events, Ecto's included.
* A stream or a `COPY ... FROM STDIN` is one span, from open to finish.
* `error.type` and `db.response.status_code` are the SQLSTATE code.
* `db.query.text` has every literal replaced by `?` by default. `query_sanitization: false`
  records the statement as it is, and `opt_out_attrs: [DBAttributes.db_query_text()]` leaves it
  out: the names OpenTelemetry Java and upstream `opentelemetry_ecto` use.
* A span can be ended from any process: a query the pool disconnects ends with the
  disconnect error, and a span whose caller exits mid-query is ended with `error.type`
  `_OTHER`. Start the `:opentelemetry_postgrex` application before calling `setup/1`.
