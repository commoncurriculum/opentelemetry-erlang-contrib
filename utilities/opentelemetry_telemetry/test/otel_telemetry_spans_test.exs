defmodule OtelTelemetrySpansTest do
  use ExUnit.Case

  require OpenTelemetry.Tracer, as: Tracer
  require Record

  for {name, spec} <- Record.extract_all(from_lib: "opentelemetry/include/otel_span.hrl") do
    Record.defrecord(name, spec)
  end

  setup do
    {:ok, _} = Application.ensure_all_started(:opentelemetry)
    :otel_simple_processor.set_exporter(:otel_exporter_pid, self())
    :ok
  end

  test "the application starts the span store" do
    assert :otel_telemetry_spans.started()
  end

  test "a span put by one process is taken by another, once" do
    ref = make_ref()
    span = Tracer.start_span("query")
    :otel_telemetry_spans.put(ref, span, %{"db.system.name": :postgresql})

    taken = Task.await(Task.async(fn -> :otel_telemetry_spans.take(ref) end))

    assert taken == {span, %{"db.system.name": :postgresql}}
    assert :otel_telemetry_spans.take(ref) == :undefined
  end

  test "the sweep ends the spans of callers that exited, and only those" do
    test = self()
    alive = make_ref()
    :otel_telemetry_spans.put(alive, Tracer.start_span("alive"), %{})

    {caller, monitor} =
      spawn_monitor(fn ->
        :otel_telemetry_spans.put(make_ref(), Tracer.start_span("orphan"), %{})
        send(test, :put)
      end)

    assert_receive :put
    assert_receive {:DOWN, ^monitor, :process, ^caller, _}

    :otel_telemetry_spans.sweep()

    assert_receive {:span,
                    span(
                      name: "orphan",
                      status: {:status, :error, "caller exited"},
                      attributes: attributes
                    )}

    assert %{"error.type": "_OTHER"} = :otel_attributes.map(attributes)
    refute_receive {:span, span(name: "alive")}
    assert {_span, %{}} = :otel_telemetry_spans.take(alive)
  end
end
