# Changelog

## Unreleased

* `db.client.connection.wait_time` and `db.client.connection.use_time` for every DBConnection
  pool, from its `[:db_connection, :checkout | :checkin]` telemetry events.
