defmodule OpentelemetryPhoenix do
  @options_schema NimbleOptions.new!(
                    endpoint_prefix: [
                      type: {:list, :atom},
                      default: [:phoenix, :endpoint],
                      doc: "The endpoint prefix in your endpoint."
                    ],
                    adapter: [
                      type: {:in, [:cowboy2, :bandit]},
                      default: :cowboy2,
                      required: true,
                      doc: "The phoenix server adapter being used.",
                      type_doc: ":atom"
                    ],
                    liveview: [
                      type: :boolean,
                      default: true,
                      doc: "Whether LiveView traces will be instrumented."
                    ],
                    controller: [
                      type: :boolean,
                      default: true,
                      doc: "Whether controller render traces will be instrumented."
                    ],
                    channel: [
                      type: :boolean,
                      default: true,
                      doc: """
                      Whether channel traces will be instrumented. Spans come only from channels that
                      `use OpentelemetryPhoenix.Channel`, since Phoenix emits no event before a channel
                      callback runs.
                      """
                    ],
                    liveview_span_names: [
                      type: {:in, [:module, :route]},
                      default: :module,
                      doc: """
                      How LiveView span names are built. `:module` names spans after the LiveView module,
                      such as `MyAppWeb.ResourceLive.mount`. `:route` names them after the operation and the
                      router route, such as `live_view.mount /resources/:resource_id`, falling back to the
                      module when the LiveView is not mounted at the router.
                      """,
                      type_doc: ":atom"
                    ]
                  )

  @moduledoc """
  OpentelemetryPhoenix uses [telemetry](https://hexdocs.pm/telemetry/) handlers to create `OpenTelemetry` spans.

  Current events which are supported include endpoint start/stop, router start/stop,
  router exceptions, LiveView lifecycle events, and controller render events.

  ### Supported options
  #{NimbleOptions.docs(@options_schema)}

  #### Adapters

  * `cowboy2` - when using PlugCowboy as your adapter you must add `:opentelemetry_cowboy` to your project
  and pass `adapter: :cowboy2` option when calling setup.
  * `bandit` - when using `Bandit.PhoenixAdapter` as your adapter you must add `:opentelemetry_bandit` to your project
  and pass `adapter: :bandit` option when calling setup

  ## Usage

  In your application start:

      def start(_type, _args) do
        :opentelemetry_cowboy.setup()
        OpentelemetryPhoenix.setup(adapter: :cowboy2)

        children = [
          {Phoenix.PubSub, name: MyApp.PubSub},
          MyAppWeb.Endpoint
        ]

        opts = [strategy: :one_for_one, name: MyStore.Supervisor]
        Supervisor.start_link(children, opts)
      end

  ## Metrics

  `setup/1` creates the `http.server.request.duration` histogram (seconds) and records one
  measurement per request that passes through the endpoint's `Plug.Telemetry`, including
  requests whose exception Phoenix renders as an error page. WebSocket upgrades are dispatched
  before `Plug.Telemetry` and are not recorded. Measurements carry `http.request.method`,
  `url.scheme`, `http.response.status_code`, `http.route` (when the router matched),
  `network.protocol.version`, and `error.type` (the status code, for 5xx responses).

  It also creates three channel metrics:

    * `phoenix.channel.count` (`{channel}`) - channels joined and still running, by
      `phoenix.socket` and `phoenix.channel`.
    * `phoenix.socket.connection.count` (`{connection}`) - socket connections with at least
      one joined channel, by `phoenix.socket`.
    * `phoenix.channel.handle_in.duration` (seconds) - one measurement per `handle_in/3`, by
      `phoenix.socket`, `phoenix.channel` and `phoenix.channel.event`.

  Recording is a no-op unless the `opentelemetry_experimental` SDK is started before `setup/1`.

  """
  require OpenTelemetryAPIExperimental.Histogram

  alias OpenTelemetry.SemConv.ErrorAttributes
  alias OpenTelemetry.SemConv.Incubating.HTTPAttributes
  alias OpenTelemetry.SemConv.Metrics.HTTPMetrics
  alias OpenTelemetry.SemConv.NetworkAttributes
  alias OpenTelemetry.SemConv.URLAttributes
  alias OpenTelemetryAPIExperimental.Histogram

  alias OpenTelemetry.Tracer

  @tracer_id __MODULE__

  @live_view_route_key {__MODULE__, :live_view_route}
  @request_start_key {__MODULE__, :request_start}
  @request_route_key {__MODULE__, :request_route}

  @known_methods HTTPAttributes.http_request_method_values()
                 |> Map.delete(:other)
                 |> Map.new(fn {_key, method} -> {Atom.to_string(method), method} end)

  @request_duration_boundaries [
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

  @typedoc "Setup options"
  @type opts :: [
          endpoint_prefix()
          | adapter()
          | liveview()
          | controller()
          | channel()
          | liveview_span_names()
        ]

  @typedoc "Attach channel handlers. Optional"
  @type channel :: {:channel, boolean()}

  @typedoc "The endpoint prefix in your endpoint. Defaults to `[:phoenix, :endpoint]`"
  @type endpoint_prefix :: {:endpoint_prefix, [atom()]}

  @typedoc "The phoenix server adapter being used. Required"
  @type adapter :: {:adapter, :cowboy2 | :bandit}

  @typedoc "Attach LiveView handlers. Optional"
  @type liveview :: {:liveview, boolean()}

  @typedoc "Attach controller render handlers. Optional"
  @type controller :: {:controller, boolean()}

  @typedoc "How LiveView span names are built. Optional"
  @type liveview_span_names :: {:liveview_span_names, :module | :route}

  @doc """
  Initializes and configures the telemetry handlers.
  """
  @spec setup(opts()) :: :ok
  def setup(opts \\ []) do
    opts = NimbleOptions.validate!(opts, @options_schema)

    attach_endpoint_start_handler(opts)
    attach_router_start_handler(opts)
    attach_request_duration_handlers(opts)
    OpentelemetryPhoenix.ChannelMetrics.setup()

    if opts[:liveview] do
      attach_liveview_handlers(opts)
    end

    if opts[:controller] do
      attach_controller_render_handlers()
    end

    if opts[:channel] do
      attach_channel_handlers()
    end

    :ok
  end

  @doc false
  def attach_endpoint_start_handler(opts) do
    :telemetry.attach(
      {__MODULE__, opts[:endpoint_prefix], :endpoint_start},
      opts[:endpoint_prefix] ++ [:start],
      &__MODULE__.handle_endpoint_start/4,
      %{adapter: opts[:adapter]}
    )
  end

  @doc false
  def attach_router_start_handler(_opts) do
    :telemetry.attach(
      {__MODULE__, :router_dispatch_start},
      [:phoenix, :router_dispatch, :start],
      &__MODULE__.handle_router_dispatch_start/4,
      %{}
    )
  end

  @doc false
  def attach_request_duration_handlers(opts) do
    Histogram.create(HTTPMetrics.http_server_request_duration(), %{
      unit: :s,
      description: "Duration of HTTP server requests.",
      advisory_params: %{explicit_bucket_boundaries: @request_duration_boundaries}
    })

    :telemetry.attach_many(
      {__MODULE__, opts[:endpoint_prefix], :request_duration},
      [opts[:endpoint_prefix] ++ [:start], opts[:endpoint_prefix] ++ [:stop]],
      &__MODULE__.handle_request_duration_event/4,
      %{}
    )

    :telemetry.attach(
      {__MODULE__, :error_rendered},
      [:phoenix, :error_rendered],
      &__MODULE__.handle_request_duration_event/4,
      %{}
    )
  end

  @doc false
  def attach_liveview_handlers(opts \\ []) do
    :telemetry.attach_many(
      {__MODULE__, :live_view},
      [
        [:phoenix, :live_view, :mount, :start],
        [:phoenix, :live_view, :mount, :stop],
        [:phoenix, :live_view, :mount, :exception],
        [:phoenix, :live_view, :handle_params, :start],
        [:phoenix, :live_view, :handle_params, :stop],
        [:phoenix, :live_view, :handle_params, :exception],
        [:phoenix, :live_view, :handle_event, :start],
        [:phoenix, :live_view, :handle_event, :stop],
        [:phoenix, :live_view, :handle_event, :exception],
        [:phoenix, :live_component, :handle_event, :start],
        [:phoenix, :live_component, :handle_event, :stop],
        [:phoenix, :live_component, :handle_event, :exception],
        [:phoenix, :live_view, :render, :start],
        [:phoenix, :live_view, :render, :stop],
        [:phoenix, :live_view, :render, :exception],
        [:phoenix, :live_component, :update, :start],
        [:phoenix, :live_component, :update, :stop],
        [:phoenix, :live_component, :update, :exception]
      ],
      &__MODULE__.handle_liveview_event/4,
      %{span_names: Keyword.get(opts, :liveview_span_names, :module)}
    )

    :ok
  end

  @doc false
  def attach_controller_render_handlers do
    :telemetry.attach_many(
      {__MODULE__, :controller_render},
      [
        [:phoenix, :controller, :render, :start],
        [:phoenix, :controller, :render, :stop],
        [:phoenix, :controller, :render, :exception]
      ],
      &__MODULE__.handle_controller_render_event/4,
      %{}
    )

    :ok
  end

  @doc false
  def attach_channel_handlers do
    :telemetry.attach_many(
      {__MODULE__, :channel},
      [
        [:phoenix, :channel, :join, :start],
        [:phoenix, :channel, :join, :stop],
        [:phoenix, :channel, :join, :exception],
        [:phoenix, :channel, :handle_in, :start],
        [:phoenix, :channel, :handle_in, :stop],
        [:phoenix, :channel, :handle_in, :exception]
      ],
      &__MODULE__.handle_channel_event/4,
      %{}
    )

    :ok
  end

  @doc false
  def handle_channel_event(
        [:phoenix, :channel, callback, :start],
        _measurements,
        %{socket: socket, channel: channel} = meta,
        _config
      ) do
    attributes =
      %{
        :"phoenix.socket" => inspect(socket.handler),
        :"phoenix.channel" => inspect(channel),
        :"phoenix.channel.event" => meta[:event]
      }
      |> Map.reject(fn {_key, value} -> is_nil(value) end)

    OpentelemetryTelemetry.start_telemetry_span(
      @tracer_id,
      channel_span_name(callback, channel, meta[:event]),
      meta,
      %{kind: :server, attributes: attributes}
    )
  end

  def handle_channel_event([:phoenix, :channel, _callback, :stop], _measurements, meta, _config) do
    OpentelemetryTelemetry.end_telemetry_span(@tracer_id, meta)
  end

  def handle_channel_event(
        [:phoenix, :channel, _callback, :exception],
        _measurements,
        %{kind: kind, reason: reason, stacktrace: stacktrace} = meta,
        _config
      ) do
    ctx = OpentelemetryTelemetry.set_current_telemetry_span(@tracer_id, meta)

    {error_type, message} =
      case Exception.normalize(kind, reason, stacktrace) do
        %{__exception__: true} = exception ->
          OpenTelemetry.Span.record_exception(ctx, exception, stacktrace, [])
          {inspect(exception.__struct__), Exception.message(exception)}

        _reason when kind == :exit ->
          {:_OTHER, "exited: #{inspect(reason)}"}

        _reason ->
          {:_OTHER, "thrown: #{inspect(reason)}"}
      end

    OpenTelemetry.Span.set_attribute(ctx, ErrorAttributes.error_type(), error_type)
    OpenTelemetry.Span.set_status(ctx, OpenTelemetry.status(:error, message))
    OpentelemetryTelemetry.end_telemetry_span(@tracer_id, meta)
    Tracer.set_current_span(ctx)
  end

  defp channel_span_name(:join, channel, _event), do: "JOIN #{inspect(channel)}"
  defp channel_span_name(:handle_in, channel, event), do: "HANDLE_IN #{inspect(channel)}##{event}"

  # TODO: do we still need exception handling? Only when cowboy?

  @doc false
  def handle_endpoint_start(_event, _measurements, _meta, %{adapter: :bandit}), do: :ok

  def handle_endpoint_start(_event, _measurements, _meta, %{adapter: :cowboy2}) do
    cowboy2_start()
  end

  defp cowboy2_start do
    OpentelemetryProcessPropagator.fetch_parent_ctx()
    |> OpenTelemetry.Ctx.attach()
  end

  @doc false
  def handle_router_dispatch_start(_event, _measurements, meta, _config) do
    attributes = %{
      :"phoenix.plug" => meta.plug,
      :"phoenix.action" => meta.plug_opts,
      HTTPAttributes.http_route() => meta.route
    }

    Process.put(@request_route_key, meta.route)

    Tracer.update_name("#{meta.conn.method} #{meta.route}")
    Tracer.set_attributes(attributes)
  end

  @doc false
  def handle_request_duration_event([:phoenix, :error_rendered], _measurements, meta, _config) do
    case Process.get(@request_start_key) do
      nil -> :ok
      start -> record_request_duration(System.monotonic_time() - start, meta.conn, meta.status)
    end
  end

  def handle_request_duration_event(event, measurements, meta, _config) do
    case List.last(event) do
      :start ->
        Process.put(@request_start_key, System.monotonic_time())
        Process.delete(@request_route_key)

      :stop ->
        record_request_duration(measurements.duration, meta.conn, meta.conn.status)
    end
  end

  defp record_request_duration(duration, conn, status) do
    route = Process.delete(@request_route_key)
    Process.delete(@request_start_key)

    attributes =
      %{
        HTTPAttributes.http_request_method() => Map.get(@known_methods, conn.method, :_OTHER),
        URLAttributes.url_scheme() => conn.scheme,
        HTTPAttributes.http_response_status_code() => status,
        HTTPAttributes.http_route() => route,
        NetworkAttributes.network_protocol_version() => protocol_version(conn),
        ErrorAttributes.error_type() => if(status >= 500, do: Integer.to_string(status))
      }
      |> Map.reject(fn {_key, value} -> is_nil(value) end)

    Histogram.record(
      HTTPMetrics.http_server_request_duration(),
      System.convert_time_unit(duration, :native, :nanosecond) / 1_000_000_000,
      attributes
    )
  end

  defp protocol_version(conn) do
    case Plug.Conn.get_http_protocol(conn) do
      :"HTTP/1.0" -> :"1.0"
      :"HTTP/1.1" -> :"1.1"
      :"HTTP/2" -> :"2"
      _ -> nil
    end
  end

  def handle_liveview_event(
        [:phoenix, _live, :mount, :start],
        _measurements,
        %{socket: %{view: live_view}} = meta,
        handler_configuration
      ) do
    route = put_live_view_route(route(meta))

    OpentelemetryTelemetry.start_telemetry_span(
      @tracer_id,
      live_view_span_name(handler_configuration, "mount", live_view, route),
      meta,
      %{kind: :server, attributes: route_attributes(route)}
    )
  end

  def handle_liveview_event(
        [:phoenix, _live, :handle_params, :start],
        _measurements,
        %{socket: %{view: live_view}} = meta,
        handler_configuration
      ) do
    route = put_live_view_route(route(meta))

    OpentelemetryTelemetry.start_telemetry_span(
      @tracer_id,
      live_view_span_name(handler_configuration, "handle_params", live_view, route),
      meta,
      %{kind: :server, attributes: route_attributes(route)}
    )
  end

  def handle_liveview_event(
        [:phoenix, _live, :handle_event, :start],
        _measurements,
        %{socket: %{view: live_view}, event: event} = meta,
        handler_configuration
      ) do
    route = live_view_route()

    OpentelemetryTelemetry.start_telemetry_span(
      @tracer_id,
      live_view_event_span_name(handler_configuration, live_view, route, event),
      meta,
      %{kind: :server, attributes: route_attributes(route)}
    )
  end

  def handle_liveview_event(
        [:phoenix, _live, :render, :start],
        _measurements,
        %{socket: %{view: live_view}, component: component} = meta,
        _handler_configuration
      ) do
    OpentelemetryTelemetry.start_telemetry_span(
      @tracer_id,
      "#{inspect(component)}.render",
      meta,
      %{attributes: %{:"live_view.module" => inspect(live_view)}}
    )
  end

  def handle_liveview_event(
        [:phoenix, _live, :render, :start],
        _measurements,
        %{socket: %{view: live_view}} = meta,
        _handler_configuration
      ) do
    OpentelemetryTelemetry.start_telemetry_span(
      @tracer_id,
      "#{inspect(live_view)}.render",
      meta,
      %{kind: :server}
    )
  end

  def handle_liveview_event(
        [:phoenix, _live, :update, :start],
        _measurements,
        %{socket: %{view: live_view}, component: component} = meta,
        _handler_configuration
      ) do
    OpentelemetryTelemetry.start_telemetry_span(
      @tracer_id,
      "#{inspect(component)}.update",
      meta,
      %{attributes: %{:"live_view.module" => inspect(live_view)}}
    )
  end

  def handle_liveview_event(
        [:phoenix, _live, _event, :stop],
        _measurements,
        meta,
        _handler_configuration
      ) do
    OpentelemetryTelemetry.end_telemetry_span(@tracer_id, meta)
  end

  def handle_liveview_event(
        [:phoenix, _live, _action, :exception],
        _,
        %{kind: kind, reason: reason, stacktrace: stacktrace} = meta,
        _
      ) do
    ctx = OpentelemetryTelemetry.set_current_telemetry_span(@tracer_id, meta)

    exception = Exception.normalize(kind, reason, stacktrace)

    OpenTelemetry.Span.record_exception(ctx, exception, stacktrace, [])
    OpenTelemetry.Span.set_status(ctx, OpenTelemetry.status(:error, ""))
    OpentelemetryTelemetry.end_telemetry_span(@tracer_id, meta)
  end

  defp route(%{uri: uri, socket: %{router: router}})
       when is_binary(uri) and not is_nil(router) do
    %URI{path: path, host: host} = URI.parse(uri)

    case Phoenix.Router.route_info(router, "GET", path || "/", host) do
      %{route: route} when is_binary(route) -> route
      _ -> nil
    end
  end

  defp route(_meta), do: nil

  defp route_attributes(nil), do: %{}
  defp route_attributes(route), do: %{HTTPAttributes.http_route() => route}

  # `handle_event` metadata carries no uri, and the socket keeps no path, so the route
  # resolved during mount/handle_params is kept for the lifetime of the LiveView process.
  defp put_live_view_route(nil) do
    Process.delete(@live_view_route_key)
    nil
  end

  defp put_live_view_route(route) do
    Process.put(@live_view_route_key, route)
    route
  end

  defp live_view_route, do: Process.get(@live_view_route_key)

  defp live_view_span_name(%{span_names: :route}, operation, live_view, route) do
    "live_view.#{operation} #{route || inspect(live_view)}"
  end

  defp live_view_span_name(_handler_configuration, operation, live_view, _route) do
    "#{inspect(live_view)}.#{operation}"
  end

  defp live_view_event_span_name(%{span_names: :route}, live_view, route, event) do
    "live_view.handle_event #{route || inspect(live_view)} #{event}"
  end

  defp live_view_event_span_name(_handler_configuration, live_view, _route, event) do
    "#{inspect(live_view)}.handle_event##{event}"
  end

  @doc false
  def handle_controller_render_event(
        [:phoenix, :controller, :render, :start],
        _measurements,
        %{view: view, template: template, format: format} = meta,
        _handler_configuration
      ) do
    OpentelemetryTelemetry.start_telemetry_span(
      @tracer_id,
      "#{inspect(view)}##{template}.#{format}",
      meta,
      %{kind: :server}
    )
  end

  def handle_controller_render_event(
        [:phoenix, :controller, :render, :stop],
        _measurements,
        meta,
        _handler_configuration
      ) do
    OpentelemetryTelemetry.end_telemetry_span(@tracer_id, meta)
  end

  def handle_controller_render_event(
        [:phoenix, :controller, :render, :exception],
        _measurements,
        %{kind: kind, reason: reason, stacktrace: stacktrace} = meta,
        _handler_configuration
      ) do
    ctx = OpentelemetryTelemetry.set_current_telemetry_span(@tracer_id, meta)

    exception = Exception.normalize(kind, reason, stacktrace)

    OpenTelemetry.Span.record_exception(ctx, exception, stacktrace, [])
    OpenTelemetry.Span.set_status(ctx, OpenTelemetry.status(:error, ""))
    OpentelemetryTelemetry.end_telemetry_span(@tracer_id, meta)
  end
end
