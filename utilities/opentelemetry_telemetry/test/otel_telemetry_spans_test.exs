defmodule OtelTelemetrySpansTest do
  use ExUnit.Case

  require OpenTelemetry.Tracer, as: Tracer
  require Record

  for {name, spec} <- Record.extract_all(from_lib: "opentelemetry/include/otel_span.hrl") do
    Record.defrecord(name, spec)
  end

  setup do
    :otel_simple_processor.set_exporter(:otel_exporter_pid, self())
    :ok
  end

  test "the application starts the span store" do
    assert :otel_telemetry_spans.started()
  end

  test "a span put by one process is taken by another, once" do
    ref = make_ref()
    span = Tracer.start_span("query")

    assert :otel_telemetry_spans.put(ref, span, %{"db.system.name": :postgresql})

    taken = Task.await(Task.async(fn -> :otel_telemetry_spans.take(ref) end))

    assert taken == {span, %{"db.system.name": :postgresql}}
    assert :otel_telemetry_spans.take(ref) == :undefined
  end

  test "the spans of a caller that exits are failed and ended as it exits" do
    alive = make_ref()
    :otel_telemetry_spans.put(alive, Tracer.start_span("alive"), %{})

    spawn(fn ->
      :otel_telemetry_spans.put(make_ref(), Tracer.start_span("orphan"), %{})
      Process.sleep(10)
    end)

    assert_receive {:span,
                    span(
                      name: "orphan",
                      start_time: start_time,
                      end_time: end_time,
                      status: {:status, :error, "_OTHER"},
                      attributes: attributes
                    )},
                   100

    assert System.convert_time_unit(end_time - start_time, :native, :millisecond) in 10..50
    assert %{"error.type": "_OTHER"} = :otel_attributes.map(attributes)
    refute_receive {:span, span(name: "alive")}
    assert {_span, %{}} = :otel_telemetry_spans.take(alive)
  end

  test "open spans outlive a restart of the store, and their callers are still watched" do
    kept = make_ref()
    :otel_telemetry_spans.put(kept, Tracer.start_span("kept"), %{})

    caller =
      spawn(fn ->
        :otel_telemetry_spans.put(make_ref(), Tracer.start_span("orphan"), %{})
        receive do: (:exit -> :ok)
      end)

    store = Process.whereis(:otel_telemetry_spans)
    monitor = Process.monitor(store)
    :sys.get_state(store)
    Process.exit(store, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^store, :killed}
    wait_for_store(store)

    send(caller, :exit)

    assert_receive {:span, span(name: "orphan")}, 100
    assert {_span, %{}} = :otel_telemetry_spans.take(kept)
  end

  defp wait_for_store(old) do
    case Process.whereis(:otel_telemetry_spans) do
      pid when is_pid(pid) and pid != old -> :sys.get_state(pid)
      _ -> Process.sleep(1) && wait_for_store(old)
    end
  end
end
