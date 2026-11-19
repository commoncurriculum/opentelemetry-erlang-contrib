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

  A client chooses the event it pushes, so `:event` is not the raw string: it is the
  `handle_in/3` clause that matches it. A clause for `"ping"` gives `"ping"`, a clause for
  `"admin-" <> _` gives `"admin-*"`, and an event no clause names gives `"_OTHER"`. Span names
  and the `phoenix.channel.event` attribute on spans and metrics use it.

  An exception, exit or throw that escapes the callback crashes the channel process, so the
  failed span stays current: the crash report that follows can link to its trace.

  ## Options

    * `:around` - `{module, function}` called as `module.function(metadata, fun)` around every
      `join/3`, `handle_in/3` and `handle_info/2`. It must call `fun` with no arguments and return
      its result. For `join/3` and `handle_in/3` it runs inside the span, which is current, so it can
      put an application's own context in place for each message and add to the span.
      `handle_info/2` metadata has `:socket`, `:channel` and `:message`, and gets no span, since it
      runs once per broadcast for every subscriber.

    * `:trace_carrier` - `{module, function}` called as `module.function(message)` with the payload
      of `join/3` and `handle_in/3` and the message of `handle_info/2`. It returns the
      `[{key, value}]` text map the message carries trace context in, or `[]`. Phoenix messages
      have no headers, so where that context lives is the application's choice. The globally
      configured propagator reads it, and the callback continues the trace it names: the span
      for `join/3` and `handle_in/3` is its child, and `handle_info/2` runs in it.
  """

  defmacro __using__(opts) do
    quote do
      @opentelemetry_phoenix_channel_around unquote(Keyword.get(opts, :around))
      @opentelemetry_phoenix_channel_trace_carrier unquote(Keyword.get(opts, :trace_carrier))
      @before_compile OpentelemetryPhoenix.Channel
    end
  end

  @doc false
  def around(nil, _metadata, fun), do: fun.()
  def around({module, function}, metadata, fun), do: apply(module, function, [metadata, fun])

  @doc false
  def span(event, around, metadata, fun) do
    :telemetry.span(event, metadata, fn -> {around(around, metadata, fun), metadata} end)
  end

  @doc false
  def continue_trace(nil, _message, fun), do: fun.()

  def continue_trace({module, function}, message, fun) do
    token =
      OpenTelemetry.Ctx.get_current()
      |> :otel_propagator_text_map.extract_to(apply(module, function, [message]))
      |> OpenTelemetry.Ctx.attach()

    result = fun.()
    OpenTelemetry.Ctx.detach(token)
    result
  end

  @doc false
  def event_clauses(module) do
    case Module.get_definition(module, {:handle_in, 3}) do
      {:v1, _kind, _meta, clauses} -> Enum.flat_map(clauses, fn {_, [event | _], _, _} -> event_clause(event) end)
      nil -> []
    end
    |> Enum.uniq()
    |> Enum.concat([quote(do: def(__opentelemetry_phoenix_event__(_event), do: "_OTHER"))])
  end

  defp event_clause(event) when is_binary(event),
    do: [quote(do: def(__opentelemetry_phoenix_event__(unquote(event)), do: unquote(event)))]

  defp event_clause({:<<>>, _, [{:"::", _, [prefix, {:binary, _, _}]} | _]}) when is_binary(prefix),
    do: [quote(do: def(__opentelemetry_phoenix_event__(unquote(prefix) <> _), do: unquote(prefix <> "*")))]

  defp event_clause({:=, _, sides}), do: Enum.flat_map(sides, &event_clause/1)
  defp event_clause(_), do: []

  defmacro __before_compile__(env) do
    around = Module.get_attribute(env.module, :opentelemetry_phoenix_channel_around)
    trace_carrier = Module.get_attribute(env.module, :opentelemetry_phoenix_channel_trace_carrier)

    [
      if Module.defines?(env.module, {:join, 3}) do
        quote do
          defoverridable join: 3

          def join(topic, payload, socket) do
            OpentelemetryPhoenix.Channel.continue_trace(unquote(trace_carrier), payload, fn ->
              OpentelemetryPhoenix.Channel.span(
                [:phoenix, :channel, :join],
                unquote(around),
                %{socket: socket, channel: __MODULE__, topic: topic},
                fn -> super(topic, payload, socket) end
              )
            end)
          end
        end
      end,
      if Module.defines?(env.module, {:handle_in, 3}) do
        quote do
          defoverridable handle_in: 3

          @doc false
          unquote_splicing(event_clauses(env.module))

          def handle_in(event, payload, socket) do
            OpentelemetryPhoenix.Channel.continue_trace(unquote(trace_carrier), payload, fn ->
              OpentelemetryPhoenix.Channel.span(
                [:phoenix, :channel, :handle_in],
                unquote(around),
                %{
                  socket: socket,
                  channel: __MODULE__,
                  topic: socket.topic,
                  event: __opentelemetry_phoenix_event__(event)
                },
                fn -> super(event, payload, socket) end
              )
            end)
          end
        end
      end,
      if (around || trace_carrier) && Module.defines?(env.module, {:handle_info, 2}) do
        quote do
          defoverridable handle_info: 2

          def handle_info(message, socket) do
            OpentelemetryPhoenix.Channel.continue_trace(unquote(trace_carrier), message, fn ->
              OpentelemetryPhoenix.Channel.around(
                unquote(around),
                %{socket: socket, channel: __MODULE__, message: message},
                fn -> super(message, socket) end
              )
            end)
          end
        end
      end
    ]
  end
end
