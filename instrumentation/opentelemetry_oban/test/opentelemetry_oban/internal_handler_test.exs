defmodule OpentelemetryOban.InternalHandlerTest do
  use DataCase

  require Record

  for {name, spec} <- Record.extract_all(from_lib: "opentelemetry/include/otel_span.hrl") do
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

    :ok
  end

  defp start_oban do
    start_supervised!(
      {Oban,
       name: __MODULE__,
       repo: TestRepo,
       queues: [events: 1],
       plugins: false,
       peer: false,
       notifier: Oban.Notifiers.PG,
       testing: :disabled}
    )
  end

  test "the engine work around a job is traced, and settling the job is a child of the job's span" do
    OpentelemetryOban.setup(internal: [])
    start_oban()

    {:ok, _job} = Oban.insert(__MODULE__, TestJob.new(%{}))

    assert_receive {:span,
                    span(
                      name: "oban.engine.insert_job",
                      kind: :internal,
                      attributes: insert_attributes
                    )},
                   5_000

    assert %{"messaging.system": :oban, "messaging.destination.name": "events"} =
             :otel_attributes.map(insert_attributes)

    assert_receive {:span,
                    span(
                      name: "oban.engine.fetch_jobs",
                      kind: :internal,
                      attributes: fetch_attributes
                    )},
                   5_000

    assert %{"messaging.system": :oban, "messaging.destination.name": "events"} =
             :otel_attributes.map(fetch_attributes)

    assert_receive {:span, span(name: "process events", span_id: job_span_id)}, 5_000

    assert_receive {:span, span(name: "oban.engine.complete_job", parent_span_id: ^job_span_id)},
                   5_000
  end

  test "an engine failure fails its span" do
    OpentelemetryOban.setup(internal: [])

    meta = %{conf: Oban.config(), engine: Oban.Engines.Basic}

    assert_raise RuntimeError, fn ->
      :telemetry.span([:oban, :engine, :fetch_jobs], meta, fn -> raise "connection lost" end)
    end

    assert_receive {:span,
                    span(
                      name: "oban.engine.fetch_jobs",
                      status: {:status, :error, message},
                      attributes: attributes
                    )}

    assert message =~ "connection lost"
    assert %{"error.type": "RuntimeError"} = :otel_attributes.map(attributes)
  end

  test "a thrown engine failure fails its span without an error type" do
    OpentelemetryOban.setup(internal: [])

    meta = %{conf: Oban.config(), engine: Oban.Engines.Basic}

    catch_throw(
      :telemetry.span([:oban, :engine, :fetch_jobs], meta, fn -> throw(:connection_lost) end)
    )

    assert_receive {:span,
                    span(
                      name: "oban.engine.fetch_jobs",
                      status: {:status, :error, message},
                      attributes: attributes
                    )}

    assert message =~ "connection_lost"
    refute Map.has_key?(:otel_attributes.map(attributes), :"error.type")
  end

  test "the engine is untraced by default" do
    OpentelemetryOban.setup()
    start_oban()

    {:ok, _job} = Oban.insert(__MODULE__, TestJob.new(%{}))

    assert_receive {:span, span(name: "process events")}, 5_000
    refute_receive {:span, span(name: "oban.engine." <> _)}, 200
  end
end
