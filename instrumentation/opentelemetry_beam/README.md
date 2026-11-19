# opentelemetry_beam

Metrics collector to export statistics from the BEAM VM.

The metrics and their names are heavily borrowed from [prometheus.erl](https://github.com/deadtrickster/prometheus.erl).

It also reports `beam.node.count`, `beam.persistent_term.count`, `beam.persistent_term.memory`,
`beam.process.message_queue_len.max` (with that process's `beam.process.registered_name` and
`beam.process.initial_call`) and `beam.scheduler.utilization`.

## System monitor spans

The application can install the VM's system monitor (`erlang:system_monitor/2`), which costs
nothing until an event fires. Each event becomes a span named `beam.process.<event>` with the
process's `beam.process.pid`, `beam.process.registered_name`, `beam.process.initial_call`,
`beam.process.memory`, `beam.process.message_queue_len` and `code.stacktrace`, linked to the span
the process was in. The same process and event are reported at most once a minute. Enable each
event in the `opentelemetry_beam` application environment:

| Setting | Span | Fires when | Extra attributes |
|---|---|---|---|
| `large_heap_bytes` | `beam.process.large_heap` | a garbage collection leaves a process's heap over this many bytes (off-heap binaries are not counted) | |
| `long_gc_ms` | `beam.process.long_gc` | a garbage collection takes at least this many milliseconds | `beam.process.gc.duration` |
| `long_schedule_ms` | `beam.process.long_schedule` | a process or port runs this many milliseconds without yielding | `beam.process.schedule.duration`, `beam.process.schedule.in`, `beam.process.schedule.out` |
| `busy_port => true` | `beam.process.busy_port` | a process is suspended sending to a busy port | `beam.port.id`, `beam.port.name` |
| `busy_dist_port => true` | `beam.process.busy_dist_port` | a process is suspended sending to another node | `beam.port.id`, `beam.port.name` |

```erlang
{opentelemetry_beam, [{large_heap_bytes, 800000000}, {long_gc_ms, 200}, {long_schedule_ms, 200},
                      {busy_port, true}, {busy_dist_port, true}]}
```

The VM allows one system monitor per node, so this replaces any other monitor installed with
`erlang:system_monitor/2`.

After installing, setup the desired metrics in your application behaviour before your
top-level supervisor starts. Make sure the API and SDK applications are started before
your application.

```erlang
opentelemetry_beam_metrics:setup(),
...
```

Metrics that are based on microstate accounting need to be enabled explicitly with the `msacc` setting in the `opt_in` option:

```erlang
opentelemetry_beam_metrics:setup(#{opt_in => #{msacc => true}}),
...
```
