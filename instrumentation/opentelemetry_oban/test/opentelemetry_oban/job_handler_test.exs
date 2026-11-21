defmodule OpentelemetryOban.JobHandlerTest do
  use DataCase

  require OpenTelemetry.Tracer
  require OpenTelemetry.Span
  require Record

  for {name, spec} <- Record.extract_all(from_lib: "opentelemetry/include/otel_span.hrl") do
    Record.defrecord(name, spec)
  end

  for {name, spec} <- Record.extract_all(from_lib: "opentelemetry_api/include/opentelemetry.hrl") do
    Record.defrecord(name, spec)
  end

  defp setup_otel do
    :application.stop(:opentelemetry)
    :application.set_env(:opentelemetry, :tracer, :otel_tracer_default)

    :application.set_env(:opentelemetry, :processors, [
      {:otel_batch_processor, %{scheduled_delay_ms: 1, exporter: {:otel_exporter_pid, self()}}}
    ])

    :application.start(:opentelemetry)
    TestHelpers.remove_oban_handlers()
  end

  describe "inline testing mode" do
    setup do
      setup_otel()
      OpentelemetryOban.setup()

      start_supervised!(
        {Oban, name: InlineOban, repo: TestRepo, testing: :inline, notifier: Oban.Notifiers.PG}
      )

      :ok
    end

    test "records the process span when the job has no persisted timestamps" do
      assert {:ok, %{state: "completed"}} =
               OpentelemetryOban.insert(InlineOban, TestJob.new(%{}))

      assert_receive {:span, span(name: "process TestJob", attributes: attributes)}

      attrs = :otel_attributes.map(attributes)
      assert %{"oban.job.worker": "TestJob", "oban.job.queue": "events"} = attrs
      refute Map.has_key?(attrs, :"oban.job.inserted_at")
    end
  end

  describe "measurements" do
    setup do
      setup_otel()
      OpentelemetryOban.setup()
      :ok
    end

    test "a job event with only a duration still ends the span, and the handler stays attached" do
      job = %Oban.Job{
        id: 1,
        queue: "events",
        worker: "TestJob",
        priority: 0,
        attempt: 1,
        max_attempts: 1,
        meta: %{}
      }

      for event <- [:stop, :exception] do
        metadata = %{
          job: job,
          kind: :error,
          reason: %RuntimeError{message: "boom"},
          stacktrace: []
        }

        :telemetry.execute([:oban, :job, :start], %{system_time: System.system_time()}, metadata)
        :telemetry.execute([:oban, :job, event], %{duration: 1_000}, metadata)

        assert_receive {:span, span(name: "process TestJob", attributes: attributes)}
        attrs = :otel_attributes.map(attributes)
        assert Map.has_key?(attrs, :"oban.job.duration_us")
        refute Map.has_key?(attrs, :"oban.job.queue_time_us")
      end

      handler_ids = Enum.map(:telemetry.list_handlers([:oban, :job]), & &1.id)
      assert "#{OpentelemetryOban.JobHandler}.job_stop" in handler_ids
      assert "#{OpentelemetryOban.JobHandler}.job_exception" in handler_ids
    end

    test "duration and queue time arrive in native units and are recorded in microseconds" do
      job = %Oban.Job{
        id: 1,
        queue: "events",
        worker: "TestJob",
        priority: 0,
        attempt: 1,
        max_attempts: 1,
        meta: %{}
      }

      :telemetry.execute([:oban, :job, :start], %{system_time: System.system_time()}, %{job: job})

      :telemetry.execute(
        [:oban, :job, :stop],
        %{
          duration: System.convert_time_unit(3, :millisecond, :native),
          queue_time: System.convert_time_unit(2, :millisecond, :native)
        },
        %{job: job}
      )

      assert_receive {:span, span(name: "process TestJob", attributes: attributes)}

      assert %{"oban.job.duration_us": 3_000, "oban.job.queue_time_us": 2_000} =
               :otel_attributes.map(attributes)
    end
  end

  describe "span_relationship: :child" do
    setup do
      setup_otel()
      OpentelemetryOban.setup(job: [span_relationship: :child])
      :ok
    end

    test "process span continues the propagated trace as a child of the send span" do
      OpenTelemetry.Tracer.with_span "parent operation" do
        parent_ctx = OpenTelemetry.Tracer.current_span_ctx()
        parent_trace_id = OpenTelemetry.Span.trace_id(parent_ctx)

        OpentelemetryOban.insert(TestJob.new(%{}))
        assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :events)

        assert_receive {:span,
                        span(
                          name: "send TestJob",
                          trace_id: ^parent_trace_id,
                          span_id: send_span_id
                        )}

        assert_receive {:span,
                        span(
                          name: "process TestJob",
                          kind: :consumer,
                          trace_id: ^parent_trace_id,
                          parent_span_id: ^send_span_id,
                          links: links
                        )}

        assert [] == :otel_links.list(links)
      end
    end

    test "process span starts a new trace when no parent context was propagated" do
      Oban.insert(TestJob.new(%{}))
      assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :events)

      assert_receive {:span,
                      span(
                        name: "process TestJob",
                        kind: :consumer,
                        parent_span_id: :undefined,
                        links: links
                      )}

      assert [] == :otel_links.list(links)
    end

    test "inner spans inside job are children of the process span" do
      OpenTelemetry.Tracer.with_span "parent operation" do
        OpentelemetryOban.insert(TestJobWithInnerSpan.new(%{}))
        assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :events)

        assert_receive {:span,
                        span(
                          name: "process TestJobWithInnerSpan",
                          kind: :consumer,
                          trace_id: process_trace_id,
                          span_id: process_span_id
                        )}

        assert_receive {:span,
                        span(
                          name: "span inside the job",
                          kind: :internal,
                          trace_id: ^process_trace_id,
                          parent_span_id: ^process_span_id
                        )}
      end
    end

    test "retries share the same propagated trace and are children of the send span" do
      OpenTelemetry.Tracer.with_span "parent operation" do
        parent_ctx = OpenTelemetry.Tracer.current_span_ctx()
        parent_trace_id = OpenTelemetry.Span.trace_id(parent_ctx)

        OpentelemetryOban.insert(TestJobThatReturnsError.new(%{}, max_attempts: 2))

        assert %{success: 0, failure: 1, discard: 1} =
                 Oban.drain_queue(queue: :events, with_scheduled: true, with_recursion: true)

        assert_receive {:span,
                        span(
                          name: "send TestJobThatReturnsError",
                          trace_id: ^parent_trace_id,
                          span_id: send_span_id
                        )}

        assert_receive {:span,
                        span(
                          name: "process TestJobThatReturnsError",
                          trace_id: first_process_trace_id,
                          parent_span_id: first_parent_span_id
                        )}

        assert_receive {:span,
                        span(
                          name: "process TestJobThatReturnsError",
                          trace_id: second_process_trace_id,
                          parent_span_id: second_parent_span_id
                        )}

        assert first_process_trace_id == parent_trace_id
        assert second_process_trace_id == parent_trace_id
        assert first_parent_span_id == send_span_id
        assert second_parent_span_id == send_span_id
      end
    end
  end

  describe "span_relationship: :link (default)" do
    setup do
      setup_otel()
      OpentelemetryOban.setup(job: [span_relationship: :link])
      :ok
    end

    test "process span creates a new trace with a link to the send span" do
      OpentelemetryOban.insert(TestJob.new(%{}))
      assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :events)

      assert_receive {:span,
                      span(
                        name: "send TestJob",
                        trace_id: send_trace_id,
                        span_id: send_span_id
                      )}

      assert_receive {:span,
                      span(
                        name: "process TestJob",
                        kind: :consumer,
                        trace_id: process_trace_id,
                        parent_span_id: :undefined,
                        links: links
                      )}

      [link(trace_id: ^send_trace_id, span_id: ^send_span_id)] = :otel_links.list(links)
      assert send_trace_id != process_trace_id
    end

    test "no link is created when no parent context was propagated" do
      Oban.insert(TestJob.new(%{}))
      assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :events)

      assert_receive {:span,
                      span(
                        name: "process TestJob",
                        kind: :consumer,
                        parent_span_id: :undefined,
                        links: links
                      )}

      assert [] == :otel_links.list(links)
    end

    test "inner spans inside job are children of the process span" do
      OpentelemetryOban.insert(TestJobWithInnerSpan.new(%{}))
      assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :events)

      assert_receive {:span,
                      span(
                        name: "process TestJobWithInnerSpan",
                        kind: :consumer,
                        trace_id: trace_id,
                        span_id: process_span_id
                      )}

      assert_receive {:span,
                      span(
                        name: "span inside the job",
                        kind: :internal,
                        trace_id: ^trace_id,
                        parent_span_id: ^process_span_id
                      )}
    end

    test "retries each create a new trace with links" do
      OpentelemetryOban.insert(TestJobThatReturnsError.new(%{}, max_attempts: 2))

      assert %{success: 0, failure: 1, discard: 1} =
               Oban.drain_queue(queue: :events, with_scheduled: true, with_recursion: true)

      assert_receive {:span,
                      span(
                        name: "send TestJobThatReturnsError",
                        trace_id: send_trace_id,
                        span_id: send_span_id
                      )}

      assert_receive {:span,
                      span(
                        name: "process TestJobThatReturnsError",
                        trace_id: first_process_trace_id,
                        links: job_1_links
                      )}

      [link(trace_id: ^send_trace_id, span_id: ^send_span_id)] = :otel_links.list(job_1_links)

      assert_receive {:span,
                      span(
                        name: "process TestJobThatReturnsError",
                        trace_id: second_process_trace_id,
                        links: job_2_links
                      )}

      [link(trace_id: ^send_trace_id, span_id: ^send_span_id)] = :otel_links.list(job_2_links)

      assert first_process_trace_id != second_process_trace_id
    end
  end

  describe "span_relationship: :none" do
    setup do
      setup_otel()
      OpentelemetryOban.setup(job: [span_relationship: :none])
      :ok
    end

    test "process span has no links and no parent context when trace was propagated" do
      OpentelemetryOban.insert(TestJob.new(%{}))
      assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :events)

      assert_receive {:span,
                      span(
                        name: "send TestJob",
                        trace_id: send_trace_id
                      )}

      assert_receive {:span,
                      span(
                        name: "process TestJob",
                        kind: :consumer,
                        trace_id: process_trace_id,
                        parent_span_id: :undefined,
                        links: links
                      )}

      assert [] == :otel_links.list(links)
      assert send_trace_id != process_trace_id
    end

    test "process span has no links when no parent context was propagated" do
      Oban.insert(TestJob.new(%{}))
      assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :events)

      assert_receive {:span,
                      span(
                        name: "process TestJob",
                        kind: :consumer,
                        parent_span_id: :undefined,
                        links: links
                      )}

      assert [] == :otel_links.list(links)
    end

    test "inner spans inside job are children of the process span" do
      OpentelemetryOban.insert(TestJobWithInnerSpan.new(%{}))
      assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :events)

      assert_receive {:span,
                      span(
                        name: "process TestJobWithInnerSpan",
                        kind: :consumer,
                        trace_id: trace_id,
                        span_id: process_span_id
                      )}

      assert_receive {:span,
                      span(
                        name: "span inside the job",
                        kind: :internal,
                        trace_id: ^trace_id,
                        parent_span_id: ^process_span_id
                      )}
    end
  end

  describe "default span_relationship" do
    setup do
      setup_otel()
      OpentelemetryOban.setup()
      :ok
    end

    test "defaults to :link behavior" do
      OpentelemetryOban.insert(TestJob.new(%{}))
      assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :events)

      assert_receive {:span,
                      span(
                        name: "send TestJob",
                        trace_id: send_trace_id,
                        span_id: send_span_id
                      )}

      assert_receive {:span,
                      span(
                        name: "process TestJob",
                        kind: :consumer,
                        trace_id: process_trace_id,
                        parent_span_id: :undefined,
                        links: links
                      )}

      [link(trace_id: ^send_trace_id, span_id: ^send_span_id)] = :otel_links.list(links)
      assert send_trace_id != process_trace_id
    end
  end

  describe "job: :disabled" do
    setup do
      setup_otel()
      OpentelemetryOban.setup(job: :disabled)
      :ok
    end

    test "does not create process spans when job handler is disabled" do
      Oban.insert(TestJob.new(%{}))
      assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :events)

      refute_receive {:span, span(name: "process TestJob")}, 100
    end
  end

  describe "messaging.process.duration" do
    setup do
      setup_otel()
      OpentelemetryOban.setup()
      Process.register(self(), :opentelemetry_oban_metrics)
      :ok
    end

    test "records one measurement per processed job, with error.type for failures" do
      before = process_duration_counts()

      for worker <- [
            TestJob,
            TestJobThatRaisesException,
            TestJobThatReturnsError,
            TestJobThatThrowsValue
          ] do
        Oban.insert(worker.new(%{}))
      end

      assert %{success: 1, discard: 3} = Oban.drain_queue(queue: :events)

      job = %{
        "messaging.system.name": :oban,
        "messaging.operation.name": "process",
        "messaging.operation.type": :process,
        "messaging.destination.name": "events"
      }

      expected =
        Map.merge(
          before,
          %{
            job => 1,
            Map.put(job, :"error.type", "UndefinedFunctionError") => 1,
            Map.put(job, :"error.type", "Oban.PerformError") => 1,
            Map.put(job, :"error.type", "Oban.CrashError") => 1
          },
          fn _attributes, count, new -> count + new end
        )

      assert process_duration_counts() == expected
    end

    test "a metrics failure leaves the job spans attached" do
      :ok = Application.stop(:opentelemetry_experimental)
      on_exit(fn -> {:ok, _} = Application.ensure_all_started(:opentelemetry_experimental) end)

      Oban.insert(TestJob.new(%{}))
      assert %{success: 1} = Oban.drain_queue(queue: :events)

      assert_receive {:span, span(name: "process TestJob")}

      handler_ids = Enum.map(:telemetry.list_handlers([:oban, :job]), & &1.id)
      assert "#{OpentelemetryOban.JobHandler}.job_stop" in handler_ids
      refute "#{OpentelemetryOban.JobHandler}.process_duration" in handler_ids
    end
  end

  for name <- [:metric, :histogram, :histogram_datapoint] do
    Record.defrecord(
      name,
      Record.extract(name, from_lib: "opentelemetry_experimental/include/otel_metrics.hrl")
    )
  end

  defp process_duration_counts do
    :otel_meter_server.force_flush()

    receive do
      {:otel_metric,
       metric(
         name: :"messaging.process.duration",
         unit: :s,
         data: histogram(datapoints: datapoints)
       )} ->
        Map.new(datapoints, fn histogram_datapoint(attributes: attributes, count: count) ->
          {attributes, count}
        end)
    after
      100 -> %{}
    end
  end
end
