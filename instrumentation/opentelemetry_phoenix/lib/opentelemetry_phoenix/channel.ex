defmodule OpentelemetryPhoenix.Channel do
  @moduledoc """
  Emits `:telemetry` span events around a channel's `join/3` and `handle_in/3`, which Phoenix
  itself only reports after they return. `OpentelemetryPhoenix.setup/1` turns them into spans
  that parent everything the callback does.

      use Phoenix.Channel
      use OpentelemetryPhoenix.Channel

  Events, each with `:start`, `:stop` and `:exception`:

    * `[:phoenix, :channel, :join]` - metadata `:socket`, `:channel` and `:topic`.
    * `[:phoenix, :channel, :handle_in]` - metadata `:socket`, `:channel`, `:topic` and `:event`.

  ## Options

    * `:around` - `{module, function}` called as `module.function(metadata, fun)` around every
      `join/3`, `handle_in/3` and `handle_info/2`, outside the span. It must call `fun` with no
      arguments and return its result. Use it to put an application's own context in place for
      each message. `handle_info/2` metadata has `:socket`, `:channel` and `:message`, and gets no
      span, since it runs once per broadcast for every subscriber.
  """

  defmacro __using__(opts) do
    quote do
      @opentelemetry_phoenix_channel_around unquote(Keyword.get(opts, :around))
      @before_compile OpentelemetryPhoenix.Channel
    end
  end

  @doc false
  def around(nil, _metadata, fun), do: fun.()
  def around({module, function}, metadata, fun), do: apply(module, function, [metadata, fun])

  @doc false
  def span(event, metadata, fun) do
    :telemetry.span(event, metadata, fn -> {fun.(), metadata} end)
  end

  defmacro __before_compile__(env) do
    around = Module.get_attribute(env.module, :opentelemetry_phoenix_channel_around)

    [
      if Module.defines?(env.module, {:join, 3}) do
        quote do
          defoverridable join: 3

          def join(topic, payload, socket) do
            metadata = %{socket: socket, channel: __MODULE__, topic: topic}

            OpentelemetryPhoenix.Channel.around(unquote(around), metadata, fn ->
              OpentelemetryPhoenix.Channel.span([:phoenix, :channel, :join], metadata, fn ->
                super(topic, payload, socket)
              end)
            end)
          end
        end
      end,
      if Module.defines?(env.module, {:handle_in, 3}) do
        quote do
          defoverridable handle_in: 3

          def handle_in(event, payload, socket) do
            metadata = %{socket: socket, channel: __MODULE__, topic: socket.topic, event: event}

            OpentelemetryPhoenix.Channel.around(unquote(around), metadata, fn ->
              OpentelemetryPhoenix.Channel.span([:phoenix, :channel, :handle_in], metadata, fn ->
                super(event, payload, socket)
              end)
            end)
          end
        end
      end,
      if around && Module.defines?(env.module, {:handle_info, 2}) do
        quote do
          defoverridable handle_info: 2

          def handle_info(message, socket) do
            OpentelemetryPhoenix.Channel.around(
              unquote(around),
              %{socket: socket, channel: __MODULE__, message: message},
              fn -> super(message, socket) end
            )
          end
        end
      end
    ]
  end
end
