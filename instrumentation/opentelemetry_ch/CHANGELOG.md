# Changelog

## Unreleased

* Spans and `db.client.operation.duration` for every query ch reports on its
  `[:ch, :query, ...]` telemetry events.
* A `Ch.stream/4` read or insert is one span, from open to finish.
