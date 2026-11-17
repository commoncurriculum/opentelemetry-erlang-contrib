# Changelog

## Unreleased

* Spans and `db.client.operation.duration` for every query Postgrex reports on its
  `[:postgrex, :query, ...]` telemetry events, Ecto's included.
* A stream or a `COPY ... FROM STDIN` is one span, from open to finish.
* `error.type` and `db.response.status_code` are the SQLSTATE code.
