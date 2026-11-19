defmodule OpentelemetryPhoenix.ChannelMetrics do
  @moduledoc false
  require OpenTelemetryAPIExperimental.Histogram
  require OpenTelemetryAPIExperimental.ObservableUpDownCounter

  alias OpenTelemetryAPIExperimental.Histogram
  alias OpenTelemetryAPIExperimental.ObservableUpDownCounter

  @channel_count :"phoenix.channel.count"
  @socket_count :"phoenix.socket.connection.count"
  @handle_in_duration :"phoenix.channel.handle_in.duration"

  @handle_in_duration_boundaries [
    0.001,
    0.0025,
    0.005,
    0.01,
    0.025,
    0.05,
    0.075,
    0.1,
    0.25,
    0.5,
    0.75,
    1,
    2.5,
    5,
    7.5,
    10
  ]

  def child_spec(_opts), do: Registry.child_spec(keys: :duplicate, name: __MODULE__)

  def setup do
    channel_count =
      ObservableUpDownCounter.create(@channel_count, %{
        unit: :"{channel}",
        description: "Channels joined and still running."
      })

    socket_count =
      ObservableUpDownCounter.create(@socket_count, %{
        unit: :"{connection}",
        description: "Socket connections with at least one joined channel."
      })

    :otel_meter.register_callback(
      :opentelemetry_experimental.get_meter(:opentelemetry.get_application_scope(__MODULE__)),
      [channel_count, socket_count],
      &__MODULE__.observe/1,
      []
    )

    Histogram.create(@handle_in_duration, %{
      unit: :s,
      description: "Duration of a channel's handle_in/3.",
      advisory_params: %{explicit_bucket_boundaries: @handle_in_duration_boundaries}
    })

    :telemetry.attach(
      {__MODULE__, :channel_joined},
      [:phoenix, :channel_joined],
      &__MODULE__.handle_channel_joined/4,
      %{}
    )

    :telemetry.attach(
      {__MODULE__, :channel_handled_in},
      [:phoenix, :channel_handled_in],
      &__MODULE__.handle_channel_handled_in/4,
      %{}
    )
  end

  def handle_channel_joined(_event, _measurements, %{result: :ok, socket: socket}, _config) do
    {:ok, _owner} =
      Registry.register(__MODULE__, socket.handler, {socket.channel, socket.transport_pid})

    :ok
  end

  def handle_channel_joined(_event, _measurements, _meta, _config), do: :ok

  def handle_channel_handled_in(
        _event,
        %{duration: duration},
        %{event: event, socket: socket},
        _config
      ) do
    Histogram.record(
      @handle_in_duration,
      System.convert_time_unit(duration, :native, :nanosecond) / 1_000_000_000,
      %{
        "phoenix.socket": inspect(socket.handler),
        "phoenix.channel": inspect(socket.channel),
        "phoenix.channel.event": event_name(socket.channel, event)
      }
    )
  end

  defp event_name(channel, event) do
    if function_exported?(channel, :__opentelemetry_phoenix_event__, 1),
      do: channel.__opentelemetry_phoenix_event__(event),
      else: event
  end

  def observe(_args) do
    channels =
      Registry.select(__MODULE__, [{{:"$1", :_, {:"$2", :"$3"}}, [], [{{:"$1", :"$2", :"$3"}}]}])

    channel_counts =
      channels
      |> Enum.frequencies_by(fn {socket, channel, _transport} -> {socket, channel} end)
      |> Enum.map(fn {{socket, channel}, count} ->
        {count, %{"phoenix.socket": inspect(socket), "phoenix.channel": inspect(channel)}}
      end)

    socket_counts =
      channels
      |> Enum.uniq_by(fn {_socket, _channel, transport} -> transport end)
      |> Enum.frequencies_by(fn {socket, _channel, _transport} -> socket end)
      |> Enum.map(fn {socket, count} -> {count, %{"phoenix.socket": inspect(socket)}} end)

    [{@channel_count, channel_counts}, {@socket_count, socket_counts}]
  end
end
