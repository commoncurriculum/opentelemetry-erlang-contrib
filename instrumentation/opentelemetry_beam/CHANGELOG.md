# Changelog

## Unreleased

### Features

* Initial release, from open-telemetry/opentelemetry-erlang-contrib#299: atom, ETS, DETS, port
  and process counts and limits, scheduler counts and run queues, `erlang:memory/0`, allocator,
  garbage collection, port I/O, context switch and reduction metrics, and opt-in microstate
  accounting and CPU time.
* `beam.node.count`: nodes in the cluster, this one included.
* `beam.cpu.scheduler.utilization`: share of time the normal and dirty CPU schedulers were busy
  since the previous observation. The application supervises the process that keeps
  `scheduler_wall_time` on and holds the previous sample.
* Memory attributes use `beam.memory.type` (`system`, `processes`, `atom`, `binary`, `code`,
  `ets`, `other`) and `beam.memory.state` (`used`, `free`) instead of the bare `kind` and
  `usage` keys.
* Names follow the semantic conventions and the `beam.cpu.*` namespace:
  * `beam.port.io` uses `network.io.direction` (`transmit`, `receive`), not `port.io.direction`.
  * `beam.dirty_io_scheduler.count` is `beam.cpu.dirty_io_scheduler.count`.
  * The opt-in `beam.process.cpu.time` is `beam.cpu.time`, opted in with `'beam.cpu.time'`. It
    reports one value, the runtime system's CPU time, with no attribute. The wall-clock datapoint
    and its `beam.process.cpu.state` attribute are gone.
  * The system monitor's `beam.process.message_queue_len` is `beam.process.message_queue.length`.
  * `beam.process.gc.duration` and `beam.process.schedule.duration` are in seconds.
