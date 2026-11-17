# Changelog

## Unreleased

* Open spans are kept in `opentelemetry_telemetry`'s shared span store.

* Spans and `db.client.operation.duration` for every query Postgrex reports on its
  `[:postgrex, :query, ...]` telemetry events, Ecto's included.
* A stream or a `COPY ... FROM STDIN` is one span, from open to finish.
* `error.type` and `db.response.status_code` are the SQLSTATE code.
* A span can be ended from any process: a query the pool disconnects ends with the
  disconnect error, and a span whose caller exits mid-query is ended with `error.type`
  `_OTHER`. Start the `:opentelemetry_postgrex` application before calling `setup/1`.
