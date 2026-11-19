defmodule OpentelemetryOban.InsertHandlerTest do
  use DataCase

  require OpenTelemetry.Tracer
  require Record

  for {name, spec} <- Record.extract_all(from_lib: "opentelemetry/include/otel_span.hrl") do
    Record.defrecord(name, spec)
  end

  for {name, spec} <- Record.extract_all(from_lib: "opentelemetry_api/include/opentelemetry.hrl") do
    Record.defrecord(name, spec)
  end

  setup do
    :application.stop(:opentelemetry)
    :application.set_env(:opentelemetry, :tracer, :otel_tracer_default)

    :application.set_env(:opentelemetry, :processors, [
      {:otel_batch_processor, %{scheduled_delay_ms: 1, exporter: {:otel_exporter_pid, self()}}}
    ])

    :application.start(:opentelemetry)

    TestHelpers.remove_oban_handlers()
    OpentelemetryOban.setup(insert: [])

    :ok
  end

  test "a plain Oban.insert adds an oban.insert event to the current span" do
    {:ok, job} =
      OpenTelemetry.Tracer.with_span "caller" do
        Oban.insert(TestJob.new(%{}))
      end

    assert_receive {:span, span(name: "caller", events: events)}

    assert [event(name: "oban.insert", attributes: attributes)] = :otel_events.list(events)

    assert %{
             "messaging.message.id": to_string(job.id),
             "messaging.destination.name": "events",
             "oban.job.worker": "TestJob"
           } == :otel_attributes.map(attributes)
  end

  test "Oban.insert_all adds one event per job" do
    OpenTelemetry.Tracer.with_span "caller" do
      Oban.insert_all([TestJob.new(%{}), TestJob.new(%{})])
    end

    assert_receive {:span, span(name: "caller", events: events)}
    assert [event(name: "oban.insert"), event(name: "oban.insert")] = :otel_events.list(events)
  end

  test "inserts add no event unless insert is turned on" do
    TestHelpers.remove_oban_handlers()
    OpentelemetryOban.setup()

    OpenTelemetry.Tracer.with_span "caller" do
      Oban.insert(TestJob.new(%{}))
    end

    assert_receive {:span, span(name: "caller", events: events)}
    assert [] == :otel_events.list(events)
  end

  test "the worker hook writes the current trace into the job's meta, so the job links to it" do
    {caller_trace_id, caller_span_id} =
      OpenTelemetry.Tracer.with_span "caller" do
        {:ok, args, opts} =
          OpentelemetryOban.InsertHandler.before_new(%{}, meta: %{"foo" => "bar"})

        {:ok, job} = Oban.insert(TestJob.new(args, opts))
        assert job.meta["foo"] == "bar"

        span_ctx = OpenTelemetry.Tracer.current_span_ctx()
        {OpenTelemetry.Span.trace_id(span_ctx), OpenTelemetry.Span.span_id(span_ctx)}
      end

    assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :events)

    assert_receive {:span, span(name: "process events", links: links)}
    assert [link(trace_id: ^caller_trace_id, span_id: ^caller_span_id)] = :otel_links.list(links)
  end

  test "the worker hook in a process with no span uses its caller's trace" do
    OpenTelemetry.Tracer.with_span "caller" do
      span_ctx = OpenTelemetry.Tracer.current_span_ctx()

      {:ok, _args, opts} =
        Task.async(fn -> OpentelemetryOban.InsertHandler.before_new(%{}, []) end) |> Task.await()

      assert opts[:meta]["traceparent"] =~ OpenTelemetry.Span.hex_trace_id(span_ctx)
    end
  end

  test "the worker hook with no trace anywhere leaves the job without trace context" do
    assert {:ok, %{}, [meta: %{}]} = OpentelemetryOban.InsertHandler.before_new(%{}, [])
  end
end
