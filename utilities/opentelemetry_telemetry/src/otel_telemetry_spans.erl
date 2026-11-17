-module(otel_telemetry_spans).

-behaviour(gen_server).

-export([start_link/0, put/3, take/1, started/0, sweep/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(SWEEP_INTERVAL, 10000).

%% Open spans keyed by a telemetry span context, for spans whose start and stop events can fire
%% in different processes. A span whose caller exits before it is taken is ended by the sweep.

-spec start_link() -> gen_server:start_ret().
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec put(reference(), opentelemetry:span_ctx(), map()) -> true.
put(Ref, SpanCtx, Attributes) ->
    ets:insert(?MODULE, {Ref, SpanCtx, Attributes, self()}).

-spec take(reference()) -> {opentelemetry:span_ctx(), map()} | undefined.
take(Ref) ->
    case ets:take(?MODULE, Ref) of
        [{Ref, SpanCtx, Attributes, _Caller}] -> {SpanCtx, Attributes};
        [] -> undefined
    end.

-spec started() -> boolean().
started() ->
    ets:whereis(?MODULE) =/= undefined.

-spec sweep() -> ok.
sweep() ->
    Callers = ets:select(?MODULE, [{{'$1', '_', '_', '$2'}, [], [{{'$1', '$2'}}]}]),
    lists:foreach(
        fun({Ref, Caller}) ->
            case is_process_alive(Caller) of
                true -> ok;
                false -> end_orphan(ets:take(?MODULE, Ref))
            end
        end,
        Callers
    ).

end_orphan([{_Ref, SpanCtx, _Attributes, _Caller}]) ->
    _ = otel_span:set_attributes(SpanCtx, #{'error.type' => <<"_OTHER">>}),
    _ = otel_span:set_status(SpanCtx, opentelemetry:status(error, <<"caller exited">>)),
    _ = otel_span:end_span(SpanCtx),
    ok;
end_orphan([]) ->
    ok.

init([]) ->
    ?MODULE = ets:new(?MODULE, [named_table, public, set, {write_concurrency, true}]),
    schedule_sweep(),
    {ok, #{}}.

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info(sweep, State) ->
    sweep(),
    schedule_sweep(),
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

schedule_sweep() ->
    erlang:send_after(?SWEEP_INTERVAL, self(), sweep).
