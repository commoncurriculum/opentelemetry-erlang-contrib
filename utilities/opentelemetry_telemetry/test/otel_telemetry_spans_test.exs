defmodule OtelTelemetrySpansTest do
  use ExUnit.Case

  require OpenTelemetry.Tracer, as: Tracer

  def orphaned(span, attributes, duration), do: send(attributes.test, {:orphaned, span, duration})
  def raising(_span, _attributes, _duration), do: raise("handler failed")

  test "the application starts the span store" do
    assert :otel_telemetry_spans.started()
  end

  test "a span put by one process is taken by another, once" do
    ref = make_ref()
    span = Tracer.start_span("query")
    :otel_telemetry_spans.put(ref, span, %{"db.system.name": :postgresql}, &__MODULE__.orphaned/3)

    taken = Task.await(Task.async(fn -> :otel_telemetry_spans.take(ref) end))

    assert taken == {span, %{"db.system.name": :postgresql}}
    assert :otel_telemetry_spans.take(ref) == :undefined
  end

  test "the sweep hands the spans of callers that exited to their orphan fun, with how long they were open" do
    test = self()
    alive = make_ref()

    :otel_telemetry_spans.put(
      alive,
      Tracer.start_span("alive"),
      %{test: test},
      &__MODULE__.orphaned/3
    )

    {caller, monitor} =
      spawn_monitor(fn ->
        :otel_telemetry_spans.put(make_ref(), :orphan, %{test: test}, &__MODULE__.orphaned/3)
        :otel_telemetry_spans.put(make_ref(), :raising, %{test: test}, &__MODULE__.raising/3)
        Process.sleep(10)
      end)

    assert_receive {:DOWN, ^monitor, :process, ^caller, _}

    :otel_telemetry_spans.sweep()

    assert_receive {:orphaned, :orphan, duration}
    assert System.convert_time_unit(duration, :native, :millisecond) >= 10
    refute_receive {:orphaned, _alive, _duration}
    assert {_span, %{}} = :otel_telemetry_spans.take(alive)
  end
end
