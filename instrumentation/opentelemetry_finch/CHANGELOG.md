# Changelog

## Unreleased

### Added

* Added the `pool_metrics: [name: finch_name, pools: [:default | url]]` setup option. It reports
  `http.client.open_connections` (`http.connection.state` `active`) for each HTTP/1 pool started
  with `start_pool_metrics?: true`, by `server.address`, `server.port` and `url.scheme`. Adds a
  dependency on `opentelemetry_api_experimental`, and `finch` becomes an optional dependency.

### Changed

* Replace deprecated `OpenTelemetry.SemanticConventions.Trace` attributes with `opentelemetry_semantic_conventions` >= v1.27.0 modules (`HTTPAttributes`, `ServerAttributes`, `URLAttributes`)

### Fixed

* Leave the span status description unset for 4xx and 5xx responses, since the reason is inferable from `http.response.status_code`

## 0.3.0

### Changed

* Update OpenTelemetry API and Semantic Conventions

## 0.2.0

* Span attributes update

## 0.1.0

* Initial release
