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

  test "a plain Oban.insert records a send producer span under the current span" do
    {:ok, job} =
      OpenTelemetry.Tracer.with_span "caller" do
        Oban.insert(TestJob.new(%{}))
      end

    assert_receive {:span, span(name: "caller", span_id: caller_span_id)}

    assert_receive {:span,
                    span(
                      name: "send events",
                      kind: :producer,
                      parent_span_id: ^caller_span_id,
                      attributes: attributes
                    )}

    assert %{
             "messaging.system.name": :oban,
             "messaging.operation.name": "send",
             "messaging.operation.type": :create,
             "messaging.client.id": "TestJob",
             "messaging.destination.name": "events",
             "messaging.message.id": job.id,
             "oban.job.worker": "TestJob",
             "oban.job.job_id": job.id,
             "oban.job.priority": 0,
             "oban.job.max_attempts": 1
           } == :otel_attributes.map(attributes)
  end

  test "Oban.insert_all records one send span with the batch's size" do
    OpenTelemetry.Tracer.with_span "caller" do
      Oban.insert_all([TestJob.new(%{}), TestJob.new(%{})])
    end

    assert_receive {:span, span(name: "caller", span_id: caller_span_id)}

    assert_receive {:span,
                    span(
                      name: "send",
                      kind: :producer,
                      parent_span_id: ^caller_span_id,
                      attributes: attributes
                    )}

    assert %{"messaging.batch.message_count": 2, "messaging.system.name": :oban} =
             :otel_attributes.map(attributes)
  end

  test "with the internal handler on too, an insert's work is its send span and the caller stays current" do
    TestHelpers.remove_oban_handlers()
    OpentelemetryOban.setup(insert: [], internal: [])

    OpenTelemetry.Tracer.with_span "caller" do
      caller = OpenTelemetry.Tracer.current_span_ctx()
      Oban.insert(TestJob.new(%{}))
      assert OpenTelemetry.Tracer.current_span_ctx() == caller
      Oban.insert_all([TestJob.new(%{})])
      assert OpenTelemetry.Tracer.current_span_ctx() == caller
    end

    assert_receive {:span, span(name: "caller", span_id: caller_span_id)}
    assert_receive {:span, span(name: "send events", parent_span_id: ^caller_span_id)}
    assert_receive {:span, span(name: "send", parent_span_id: ^caller_span_id)}
    refute_receive {:span, span(name: "oban.engine.insert_job")}
    refute_receive {:span, span(name: "oban.engine.insert_all_jobs")}
  end

  test "inserts record no span unless insert is turned on" do
    TestHelpers.remove_oban_handlers()
    OpentelemetryOban.setup()

    OpenTelemetry.Tracer.with_span "caller" do
      Oban.insert(TestJob.new(%{}))
    end

    assert_receive {:span, span(name: "caller")}
    refute_receive {:span, span(name: "send events")}
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
