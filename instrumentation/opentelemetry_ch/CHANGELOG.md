# Changelog

## Unreleased

* Open spans are kept in `opentelemetry_telemetry`'s shared span store.

* Spans and `db.client.operation.duration` for every query ch reports on its
  `[:ch, :query, ...]` telemetry events.
* A `Ch.stream/4` read or insert is one span, from open to finish.
* `db.response.returned_rows` on reads.
* `db.query.text` has every literal replaced by `?` by default. `query_sanitization: false`
  records the statement as it is, and `opt_out_attrs: [DBAttributes.db_query_text()]` leaves it
  out: the names OpenTelemetry Java and upstream `opentelemetry_ecto` use.
* A span can be ended from any process: a query the pool disconnects ends with the
  disconnect error, and a span whose caller exits mid-query is ended with `error.type`
  `_OTHER`. Start the `:opentelemetry_ch` application before calling `setup/1`.
