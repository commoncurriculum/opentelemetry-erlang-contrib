-module(otel_db_client).

-export([attach/3, handle_event/4, operation_name/1, span_name/1, start/4, start/5, stop/3]).

-include_lib("kernel/include/logger.hrl").

-define(DURATION, 'db.client.operation.duration').
-define(BOUNDARIES, [0.001, 0.005, 0.01, 0.05, 0.1, 0.5, 1, 5, 10]).

%% A database client instrumentation: Module:handle/4 receives each event, calls start/4 on the
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
-spec start(module(), reference(), map(), map()) -> ok.
start(Module, Key, Attributes, SpanAttributes) ->
    start(Module, Key, Attributes, SpanAttributes, self()).

%% Caller is the process the query runs for, when the driver runs it in another process: the span
%% is a child of the caller's current span.
-spec start(module(), reference(), map(), map(), pid()) -> ok.
start(Module, Key, Attributes, SpanAttributes, Caller) ->
    Span = otel_tracer:start_span(parent_context(Caller), tracer(Module), span_name(Attributes), #{
        kind => client,
        attributes => maps:merge(Attributes, SpanAttributes)
    }),
    otel_telemetry_spans:put(Key, Span, {Module, Attributes}) orelse otel_span:end_span(Span),
    ok.

%% db.operation.name from a command a driver reports as an atom, such as Postgrex's
%% create_table: the command as the database writes it, CREATE TABLE.
-spec operation_name(atom()) -> unicode:unicode_binary() | undefined.
operation_name(Command) when Command =:= undefined; Command =:= nil ->
    undefined;
operation_name(Command) when is_atom(Command) ->
    string:uppercase(binary:replace(atom_to_binary(Command), <<"_">>, <<" ">>, [global])).

%% The semantic conventions' span name: db.query.summary; else the operation and its target; else
%% the target alone; else db.system.name. The operation is written in SCREAMING_SNAKE_CASE, so a
%% name reads the same for every database (FIND_AND_MODIFY users, SELECT users); db.operation.name
%% keeps the database's own spelling.
-spec span_name(map()) -> unicode:unicode_binary().
span_name(#{'db.query.summary' := Summary}) ->
    Summary;
span_name(Attributes) ->
    case {maps:get('db.operation.name', Attributes, undefined), target(Attributes)} of
        {undefined, undefined} -> to_binary(maps:get('db.system.name', Attributes));
        {undefined, Target} -> Target;
        {Operation, undefined} -> screaming_snake(Operation);
        {Operation, Target} -> <<(screaming_snake(Operation))/binary, " ", Target/binary>>
    end.

screaming_snake(Operation) ->
    Snake = re:replace(Operation, <<"([a-z0-9])([A-Z])">>, <<"\\1_\\2">>, [global, {return, binary}]),
    string:uppercase(binary:replace(Snake, <<" ">>, <<"_">>, [global])).

target(#{'db.collection.name' := Collection}) ->
    Collection;
target(#{'db.namespace' := Namespace}) ->
    Namespace;
target(#{'server.address' := Address, 'server.port' := Port}) ->
    <<Address/binary, ":", (integer_to_binary(Port))/binary>>;
target(#{'server.address' := Address}) ->
    Address;
target(_Attributes) ->
    undefined.

to_binary(Atom) when is_atom(Atom) -> atom_to_binary(Atom);
to_binary(Binary) -> Binary.

%% Finish(Span) returns {Attributes, SpanAttributes}, known once the query is done. Attributes join
%% the start's on the span and its duration measurement, rename the span when they change its
%% name, and fail it when they hold 'error.type'. The span ends even when Finish raises.
-spec stop(reference(), integer(), fun((opentelemetry:span_ctx()) -> {map(), map()})) -> ok.
stop(Key, Duration, Finish) ->
    case otel_telemetry_spans:take(Key) of
        {Span, {Module, StartAttributes}} ->
            Attributes =
                try
                    {StopAttributes, SpanAttributes} = Finish(Span),
                    All = maps:merge(StartAttributes, StopAttributes),
                    otel_span:set_attributes(Span, maps:merge(StopAttributes, SpanAttributes)),
                    rename(Span, span_name(StartAttributes), span_name(All)),
                    fail(Span, All),
                    All
                after
                    otel_span:end_span(Span)
                end,
            otel_histogram:record(
                otel_ctx:get_current(),
                meter(Module),
                ?DURATION,
                erlang:convert_time_unit(Duration, native, nanosecond) / 1.0e9,
                Attributes
            ),
            ok;
        undefined ->
            ok
    end.

rename(_Span, Name, Name) -> ok;
rename(Span, _Name, NewName) -> otel_span:update_name(Span, NewName).

fail(Span, #{'error.type' := Type}) ->
    otel_span:set_status(Span, opentelemetry:status(error, Type));
fail(_Span, _Errors) ->
    ok.

parent_context(Caller) when Caller =/= self() ->
    case opentelemetry_process_propagator:fetch_ctx(Caller) of
        undefined -> parent_context(self());
        Ctx -> Ctx
    end;
parent_context(_Self) ->
    Ctx = otel_ctx:get_current(),
    case otel_tracer:current_span_ctx(Ctx) of
        undefined ->
            Callers =
                case get('$callers') of
                    undefined -> [];
                    Pids -> Pids
                end,
            case opentelemetry_process_propagator:fetch_parent_ctx(length(Callers), '$callers') of
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
