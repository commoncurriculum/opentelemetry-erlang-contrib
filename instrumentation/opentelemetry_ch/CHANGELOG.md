# Changelog

## Unreleased

* Open spans are kept in `opentelemetry_telemetry`'s shared span store.

* Spans and `db.client.operation.duration` for every query ch reports on its
  `[:ch, :query, ...]` telemetry events.
* A `Ch.stream/4` read or insert is one span, from open to finish.
* `db.response.returned_rows` on reads.
* A span can be ended from any process: a query the pool disconnects ends with the
  disconnect error, and a span whose caller exits mid-query is ended with `error.type`
  `_OTHER`. Start the `:opentelemetry_ch` application before calling `setup/1`.
