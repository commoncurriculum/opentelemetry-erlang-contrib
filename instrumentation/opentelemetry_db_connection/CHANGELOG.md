# Changelog

## Unreleased

* `db.client.connection.wait_time` and `db.client.connection.use_time` for every DBConnection
  pool, from its `[:db_connection, :checkout | :checkin]` telemetry events.
* `db.client.connection.count`, `db.client.connection.max` and
  `db.client.connection.pending_requests` for every pool that starts after `setup/0`, found by
  its `[:db_connection, :pool, :init]` telemetry event.
