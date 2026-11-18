-module(otel_db_client).

-export([attach/3, handle_event/4, start/5, stop/3]).

-include_lib("kernel/include/logger.hrl").

-define(DURATION, 'db.client.operation.duration').
-define(BOUNDARIES, [0.001, 0.005, 0.01, 0.05, 0.1, 0.5, 1, 5, 10]).

%% A database client instrumentation: Module:handle/4 receives each event, calls start/5 on the
%% query's start event and stop/3 on its stop or exception event. Spans and the
%% db.client.operation.duration histogram are recorded under Module's instrumentation scope.

-spec attach(module(), [telemetry:event_name()], term()) -> ok.
attach(Module, Events, Config) ->
    otel_telemetry_spans:started() orelse
        error({not_started, opentelemetry_telemetry}),
    otel_meter:create_histogram(meter(Module), ?DURATION, #{
        unit => s,
        description => <<"Duration of database client operations.">>,
        advisory_params => #{explicit_bucket_boundaries => ?BOUNDARIES}
    }),
    _ = telemetry:attach_many(Module, Events, fun ?MODULE:handle_event/4, {Module, Config}),
    ok.

handle_event(Event, Measurements, Metadata, {Module, Config}) ->
    try
        Module:handle(Event, Measurements, Metadata, Config)
    catch
        Kind:Reason:Stacktrace ->
            ?LOG_ERROR("~ts failed: ~ts", [
                Module, erl_error:format_exception(Kind, Reason, Stacktrace)
            ])
    end.

%% Attributes go on the span and on its duration measurement; SpanAttributes only on the span.
-spec start(module(), reference(), unicode:unicode_binary(), map(), map()) -> ok.
start(Module, Key, Name, Attributes, SpanAttributes) ->
    Span = otel_tracer:start_span(parent_context(), tracer(Module), Name, #{
        kind => client,
        attributes => maps:merge(Attributes, SpanAttributes)
    }),
    otel_telemetry_spans:put(Key, Span, {Module, Attributes}) orelse otel_span:end_span(Span),
    ok.

%% Finish(Span) returns {SpanAttributes, ErrorAttributes}. The span ends even when Finish raises.
%% ErrorAttributes go on the span and its duration measurement; its 'error.type' fails the span.
-spec stop(reference(), integer(), fun((opentelemetry:span_ctx()) -> {map(), map()})) -> ok.
stop(Key, Duration, Finish) ->
    case otel_telemetry_spans:take(Key) of
        {Span, {Module, Attributes}} ->
            Errors =
                try
                    {SpanAttributes, ErrorAttributes} = Finish(Span),
                    otel_span:set_attributes(Span, maps:merge(SpanAttributes, ErrorAttributes)),
                    fail(Span, ErrorAttributes),
                    ErrorAttributes
                after
                    otel_span:end_span(Span)
                end,
            otel_histogram:record(
                otel_ctx:get_current(),
                meter(Module),
                ?DURATION,
                erlang:convert_time_unit(Duration, native, nanosecond) / 1.0e9,
                maps:merge(Attributes, Errors)
            ),
            ok;
        undefined ->
            ok
    end.

fail(Span, #{'error.type' := Type}) ->
    otel_span:set_status(Span, opentelemetry:status(error, Type));
fail(_Span, _Errors) ->
    ok.

parent_context() ->
    Ctx = otel_ctx:get_current(),
    case otel_tracer:current_span_ctx(Ctx) of
        undefined ->
            case opentelemetry_process_propagator:fetch_parent_ctx(1, '$callers') of
                undefined -> Ctx;
                Parent -> Parent
            end;
        _Span ->
            Ctx
    end.

tracer(Module) ->
    opentelemetry:get_application_tracer(Module).

meter(Module) ->
    opentelemetry_experimental:get_meter(opentelemetry:get_application_scope(Module)).
