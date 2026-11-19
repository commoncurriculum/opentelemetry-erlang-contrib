defmodule OpentelemetryPhoenix.ChannelTest do
  use ExUnit.Case, async: false

  @moduletag :capture_log

  require OpenTelemetry.Tracer
  require Record

  for {name, spec} <- Record.extract_all(from_lib: "opentelemetry/include/otel_span.hrl") do
    Record.defrecord(name, spec)
  end

  for {name, spec} <- Record.extract_all(from_lib: "opentelemetry_api/include/opentelemetry.hrl") do
    Record.defrecord(name, spec)
  end

  defmodule Context do
    def around(metadata, fun) do
      send(
        metadata.socket.assigns.test,
        {:around, Map.delete(metadata, :socket), OpenTelemetry.Tracer.current_span_ctx()}
      )

      Process.put(:around_context, metadata.socket.assigns.context)

      try do
        fun.()
      after
        Process.delete(:around_context)
      end
    end
  end

  defmodule RoomChannel do
    use Phoenix.Channel
    use OpentelemetryPhoenix.Channel

    def join("room:" <> _id, _params, socket) do
      OpenTelemetry.Tracer.with_span "inside join" do
        {:ok, socket}
      end
    end

    def join(_topic, _params, _socket), do: {:error, %{reason: "unauthorized"}}

    def handle_in("ping", _params, socket) do
      OpenTelemetry.Tracer.with_span "inside handle_in" do
        {:reply, :ok, socket}
      end
    end

    def handle_in("crash", _params, _socket), do: raise("boom")
    def handle_in("exit", _params, _socket), do: exit(:killed)
    def handle_in("throw", _params, _socket), do: throw(:ball)
  end

  defmodule ContextChannel do
    use Phoenix.Channel
    use OpentelemetryPhoenix.Channel, around: {Context, :around}

    def join(_topic, _params, socket), do: {:ok, socket}

    def handle_in("context", _params, socket) do
      {:reply, {:ok, %{context: Process.get(:around_context)}}, socket}
    end

    def handle_info(:context, socket) do
      send(socket.assigns.test, {:handle_info_context, Process.get(:around_context)})
      {:noreply, socket}
    end
  end

  defmodule Carrier do
    def trace_carrier(%{"meta" => meta}), do: Map.to_list(meta)
    def trace_carrier({:traced, meta}), do: Map.to_list(meta)
    def trace_carrier(_message), do: []
  end

  defmodule TracedChannel do
    use Phoenix.Channel
    use OpentelemetryPhoenix.Channel, trace_carrier: {Carrier, :trace_carrier}

    def join(_topic, _params, socket), do: {:ok, socket}

    def handle_in("ping", _params, socket) do
      OpenTelemetry.Tracer.with_span "inside handle_in" do
        {:reply, :ok, socket}
      end
    end

    def handle_info({:traced, _meta}, socket) do
      send(socket.assigns.test, {:handle_info_span_ctx, OpenTelemetry.Tracer.current_span_ctx()})
      {:noreply, socket}
    end
  end

  defmodule UserSocket do
    use Phoenix.Socket

    channel("traced:*", TracedChannel)

    channel("room:*", RoomChannel)
    channel("private:*", RoomChannel)
    channel("context:*", ContextChannel)

    def connect(_params, socket), do: {:ok, socket}
    def id(_socket), do: nil
  end

  defmodule Endpoint do
    use Phoenix.Endpoint, otp_app: :opentelemetry_phoenix

    socket("/socket", UserSocket)
  end

  import Phoenix.ChannelTest

  @endpoint Endpoint

  setup do
    :otel_simple_processor.set_exporter(:otel_exporter_pid, self())

    on_exit(fn ->
      Enum.each(:telemetry.list_handlers([]), &:telemetry.detach(&1.id))
    end)

    start_supervised!({Phoenix.PubSub, name: __MODULE__.PubSub})
    start_supervised!({Endpoint, pubsub_server: __MODULE__.PubSub, server: false})

    OpentelemetryPhoenix.setup(adapter: :cowboy2)

    :ok
  end

  test "join gets a span that parents the work inside it" do
    {:ok, _reply, _socket} = UserSocket |> socket(nil, %{}) |> subscribe_and_join(RoomChannel, "room:1")

    assert_receive {:span,
                    span(
                      name: "JOIN OpentelemetryPhoenix.ChannelTest.RoomChannel",
                      kind: :server,
                      span_id: join_span_id,
                      attributes: attributes
                    )}

    assert %{
             "phoenix.socket": inspect(UserSocket),
             "phoenix.channel": inspect(RoomChannel)
           } == :otel_attributes.map(attributes)

    assert_receive {:span, span(name: "inside join", parent_span_id: ^join_span_id)}
  end

  test "handle_in gets a span named after its event that parents the work inside it" do
    {:ok, _reply, socket} = UserSocket |> socket(nil, %{}) |> subscribe_and_join(RoomChannel, "room:1")

    ref = push(socket, "ping", %{})
    assert_reply(ref, :ok)

    assert_receive {:span,
                    span(
                      name: "HANDLE_IN OpentelemetryPhoenix.ChannelTest.RoomChannel#ping",
                      kind: :server,
                      span_id: handle_in_span_id,
                      attributes: attributes
                    )}

    assert %{
             "phoenix.socket": inspect(UserSocket),
             "phoenix.channel": inspect(RoomChannel),
             "phoenix.channel.event": "ping"
           } == :otel_attributes.map(attributes)

    assert_receive {:span, span(name: "inside handle_in", parent_span_id: ^handle_in_span_id)}
  end

  test "a refused join still ends its span" do
    {:error, _reply} = UserSocket |> socket(nil, %{}) |> subscribe_and_join(RoomChannel, "private:1")

    assert_receive {:span, span(name: "JOIN OpentelemetryPhoenix.ChannelTest.RoomChannel")}
  end

  test "a handle_in that raises fails its span" do
    {:ok, _reply, socket} = UserSocket |> socket(nil, %{}) |> subscribe_and_join(RoomChannel, "room:1")
    Process.unlink(socket.channel_pid)

    push(socket, "crash", %{})

    assert_receive {:span,
                    span(
                      name: "HANDLE_IN OpentelemetryPhoenix.ChannelTest.RoomChannel#crash",
                      status: {:status, :error, "boom"},
                      attributes: attributes,
                      events: events
                    )}

    assert :otel_attributes.map(attributes)[:"error.type"] == "RuntimeError"
    assert [event(name: :exception)] = :otel_events.list(events)
  end

  test "a handle_in that exits or throws fails its span without an exception event" do
    socket = %Phoenix.Socket{handler: UserSocket, topic: "room:1"}

    assert catch_exit(RoomChannel.handle_in("exit", %{}, socket)) == :killed

    assert_receive {:span,
                    span(
                      name: "HANDLE_IN OpentelemetryPhoenix.ChannelTest.RoomChannel#exit",
                      status: {:status, :error, "exited: :killed"},
                      attributes: attributes,
                      events: events
                    )}

    assert :otel_attributes.map(attributes)[:"error.type"] == :_OTHER
    assert [] == :otel_events.list(events)

    assert catch_throw(RoomChannel.handle_in("throw", %{}, socket)) == :ball

    assert_receive {:span,
                    span(
                      name: "HANDLE_IN OpentelemetryPhoenix.ChannelTest.RoomChannel#throw",
                      status: {:status, :error, "thrown: :ball"}
                    )}
  end

  test "no spans when channel tracing is off" do
    Enum.each(:telemetry.list_handlers([]), &:telemetry.detach(&1.id))
    OpentelemetryPhoenix.setup(adapter: :cowboy2, channel: false)

    {:ok, _reply, socket} = UserSocket |> socket(nil, %{}) |> subscribe_and_join(RoomChannel, "room:1")
    ref = push(socket, "ping", %{})
    assert_reply(ref, :ok)

    assert_receive {:span, span(name: "inside handle_in", parent_span_id: :undefined)}
    refute_received {:span, span(name: "JOIN OpentelemetryPhoenix.ChannelTest.RoomChannel")}
  end

  test "around runs inside the span for join and handle_in, and alone for handle_info" do
    {:ok, _reply, socket} =
      UserSocket
      |> socket(nil, %{test: self(), context: "from the socket"})
      |> subscribe_and_join(ContextChannel, "context:1")

    assert_receive {:around, %{channel: ContextChannel, topic: "context:1"}, join_span_ctx}
    join_span_id = OpenTelemetry.Span.span_id(join_span_ctx)
    assert_receive {:span, span(name: "JOIN " <> _, span_id: ^join_span_id)}

    ref = push(socket, "context", %{})
    assert_reply(ref, :ok, %{context: "from the socket"})

    assert_receive {:around, %{channel: ContextChannel, topic: "context:1", event: "context"}, handle_in_span_ctx}

    handle_in_span_id = OpenTelemetry.Span.span_id(handle_in_span_ctx)
    assert_receive {:span, span(name: "HANDLE_IN " <> _, span_id: ^handle_in_span_id)}

    send(socket.channel_pid, :context)
    assert_receive {:around, %{channel: ContextChannel, message: :context}, :undefined}
    assert_receive {:handle_info_context, "from the socket"}
  end

  test "a failed callback's span stays current, so the crash report can link to its trace" do
    socket = %Phoenix.Socket{handler: UserSocket, topic: "room:1"}

    assert_raise RuntimeError, fn -> RoomChannel.handle_in("crash", %{}, socket) end
    current_span_id = OpenTelemetry.Span.span_id(OpenTelemetry.Tracer.current_span_ctx())

    assert_receive {:span, span(name: "HANDLE_IN " <> _, span_id: ^current_span_id)}
  end

  @trace_id 0x4BF92F3577B34DA6A3CE929D0E0E4736
  @parent_span_id 0x00F067AA0BA902B7
  @traceparent "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"

  test "join and handle_in continue the trace their payload carries, and leave the process as it was" do
    {:ok, _reply, socket} =
      UserSocket
      |> socket(nil, %{test: self()})
      |> subscribe_and_join(TracedChannel, "traced:1", %{"meta" => %{"traceparent" => @traceparent}})

    assert_receive {:span, span(name: "JOIN " <> _, trace_id: @trace_id, parent_span_id: @parent_span_id)}

    ref = push(socket, "ping", %{"meta" => %{"traceparent" => @traceparent}})
    assert_reply(ref, :ok)

    assert_receive {:span,
                    span(
                      name: "HANDLE_IN OpentelemetryPhoenix.ChannelTest.TracedChannel#ping",
                      trace_id: @trace_id,
                      parent_span_id: @parent_span_id,
                      span_id: handle_in_span_id
                    )}

    assert_receive {:span, span(name: "inside handle_in", trace_id: @trace_id, parent_span_id: ^handle_in_span_id)}

    ref = push(socket, "ping", %{})
    assert_reply(ref, :ok)

    assert_receive {:span, span(name: "HANDLE_IN " <> _, trace_id: trace_id, parent_span_id: :undefined)}
    refute trace_id == @trace_id
  end

  test "handle_info runs in the trace its message carries" do
    {:ok, _reply, socket} = UserSocket |> socket(nil, %{test: self()}) |> subscribe_and_join(TracedChannel, "traced:1")

    send(socket.channel_pid, {:traced, %{"traceparent" => @traceparent}})

    assert_receive {:handle_info_span_ctx, span_ctx}
    assert OpenTelemetry.Span.trace_id(span_ctx) == @trace_id
    assert OpenTelemetry.Span.span_id(span_ctx) == @parent_span_id
  end
end
