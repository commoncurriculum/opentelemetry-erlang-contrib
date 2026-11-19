defmodule OpentelemetryPhoenix.ChannelMetricsTest do
  use ExUnit.Case, async: false

  @moduletag :capture_log

  require Record

  for name <- [:metric, :sum, :datapoint, :histogram, :histogram_datapoint] do
    Record.defrecord(
      name,
      Record.extract(name, from_lib: "opentelemetry_experimental/include/otel_metrics.hrl")
    )
  end

  defmodule RoomChannel do
    use Phoenix.Channel

    def join("room:" <> _id, _params, socket), do: {:ok, socket}
    def join(_topic, _params, _socket), do: {:error, %{reason: "unauthorized"}}

    def handle_in("ping", _params, socket), do: {:reply, :ok, socket}
  end

  defmodule TracedChannel do
    use Phoenix.Channel
    use OpentelemetryPhoenix.Channel

    def join(_topic, _params, socket), do: {:ok, socket}
    def handle_in(_event, _params, socket), do: {:reply, :ok, socket}
  end

  defmodule UserSocket do
    use Phoenix.Socket

    channel("traced:*", TracedChannel)
    channel("room:*", RoomChannel)
    channel("private:*", RoomChannel)

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
    readers = Application.get_env(:opentelemetry_experimental, :readers)
    :ok = Application.stop(:opentelemetry_experimental)

    Application.put_env(:opentelemetry_experimental, :readers, [
      %{
        module: :otel_metric_reader,
        config: %{
          exporter: {:otel_metric_exporter_pid, self()},
          default_temporality_mapping: %{histogram: :temporality_cumulative}
        }
      }
    ])

    {:ok, _} = Application.ensure_all_started(:opentelemetry_experimental)

    on_exit(fn ->
      :ok = Application.stop(:opentelemetry_experimental)
      Application.put_env(:opentelemetry_experimental, :readers, readers)
      {:ok, _} = Application.ensure_all_started(:opentelemetry_experimental)
      :telemetry.list_handlers([]) |> Enum.each(&:telemetry.detach(&1.id))
    end)

    start_supervised!({Phoenix.PubSub, name: __MODULE__.PubSub})
    start_supervised!({Endpoint, pubsub_server: __MODULE__.PubSub, server: false})

    OpentelemetryPhoenix.setup(adapter: :cowboy2)

    :ok
  end

  test "counts joined channels and the sockets they ride on, until they leave" do
    OpentelemetryPhoenix.setup(adapter: :cowboy2, endpoint_prefix: [:second, :endpoint])

    socket = socket(UserSocket, nil, %{})
    {:ok, _reply, first} = subscribe_and_join(socket, RoomChannel, "room:1")
    {:ok, _reply, _second} = subscribe_and_join(socket, RoomChannel, "room:2")
    {:error, _reply} = subscribe_and_join(socket, RoomChannel, "private:1")

    assert counts() == expected_counts(2)

    Process.unlink(first.channel_pid)
    monitor = Process.monitor(first.channel_pid)
    ref = leave(first)
    assert_reply(ref, :ok)
    assert_receive {:DOWN, ^monitor, :process, _pid, _reason}

    assert await_counts(expected_counts(1)) == expected_counts(1)
  end

  test "records phoenix.channel.handle_in.duration by event" do
    {:ok, _reply, socket} =
      UserSocket
      |> socket(nil, %{})
      |> subscribe_and_join(RoomChannel, "room:1")

    for _ <- 1..2 do
      ref = push(socket, "ping", %{})
      assert_reply(ref, :ok)
    end

    :otel_meter_server.force_flush()

    assert_receive {:otel_metric,
                    metric(
                      name: :"phoenix.channel.handle_in.duration",
                      unit: :s,
                      data: histogram(datapoints: [histogram_datapoint(attributes: attributes, count: 2)])
                    )}

    assert attributes == %{
             "phoenix.socket": inspect(UserSocket),
             "phoenix.channel": inspect(RoomChannel),
             "phoenix.channel.event": "ping"
           }
  end

  test "a traced channel records the event its clauses name, so a client can't add attribute values" do
    {:ok, _reply, socket} = UserSocket |> socket(nil, %{}) |> subscribe_and_join(TracedChannel, "traced:1")

    for event <- ["made-up-1", "made-up-2"] do
      ref = push(socket, event, %{})
      assert_reply(ref, :ok)
    end

    :otel_meter_server.force_flush()

    assert_receive {:otel_metric,
                    metric(
                      name: :"phoenix.channel.handle_in.duration",
                      data: histogram(datapoints: [histogram_datapoint(attributes: attributes, count: 2)])
                    )}

    assert attributes[:"phoenix.channel.event"] == "_OTHER"
  end

  defp expected_counts(channels) do
    %{
      {:"phoenix.channel.count", %{"phoenix.socket": inspect(UserSocket), "phoenix.channel": inspect(RoomChannel)}} =>
        channels,
      {:"phoenix.socket.connection.count", %{"phoenix.socket": inspect(UserSocket)}} => 1
    }
  end

  defp counts do
    :otel_meter_server.force_flush()
    Map.merge(receive_counts(:"phoenix.channel.count"), receive_counts(:"phoenix.socket.connection.count"))
  end

  # Registry drops a process's entries after it handles the process's exit signal.
  defp await_counts(expected, attempts \\ 50) do
    counts = counts()

    if counts == expected or attempts == 0 do
      counts
    else
      Process.sleep(20)
      await_counts(expected, attempts - 1)
    end
  end

  defp receive_counts(name) do
    receive do
      {:otel_metric, metric(name: ^name, data: sum(datapoints: datapoints))} ->
        datapoints
        |> Enum.reject(&(datapoint(&1, :value) == 0))
        |> Map.new(&{{name, datapoint(&1, :attributes)}, datapoint(&1, :value)})
    after
      1_000 -> flunk("no #{name}")
    end
  end
end
