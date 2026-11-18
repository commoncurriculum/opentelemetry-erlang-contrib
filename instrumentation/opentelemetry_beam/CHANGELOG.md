# Changelog

## Unreleased

### Features

* Initial release, from open-telemetry/opentelemetry-erlang-contrib#299: atom, ETS, DETS, port
  and process counts and limits, scheduler counts and run queues, `erlang:memory/0`, allocator,
  garbage collection, port I/O, context switch and reduction metrics, and opt-in microstate
  accounting and CPU time.
* `beam.node.count`: nodes in the cluster, this one included.
* `beam.process.message_queue_len.max`: the longest message queue of any process, with
  `beam.process.registered_name` and `beam.process.initial_call` (the `proc_lib` initial call
  when the process has one).
* `beam.scheduler.utilization`: share of time the normal and dirty CPU schedulers were busy
  since the previous observation. The application supervises the process that keeps
  `scheduler_wall_time` on and holds the previous sample.
* Memory attributes use `beam.memory.type` (`system`, `processes`, `atom`, `binary`, `code`,
  `ets`, `other`) and `beam.memory.state` (`used`, `free`) instead of the bare `kind` and
  `usage` keys.
* Fixed the opt-in `beam.process.cpu.time` wall-clock datapoint, which carried
  `process.cpu.state` instead of `beam.process.cpu.state`.
