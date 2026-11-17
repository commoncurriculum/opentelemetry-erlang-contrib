-module(otel_telemetry_spans).

-behaviour(gen_server).

-export([create_tables/0, start_link/0, put/3, take/1, started/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

%% Open spans keyed by a telemetry span context. The store monitors every process that puts a
%% span and, the moment one exits, fails and ends each span it still holds. The tables belong to
%% the application, so a store restart loses nothing.

-define(CALLERS, otel_telemetry_spans_callers).

-spec create_tables() -> ok.
create_tables() ->
    ?MODULE = ets:new(?MODULE, [named_table, public, set, {write_concurrency, true}]),
    ?CALLERS = ets:new(?CALLERS, [named_table, public, set, {write_concurrency, true}]),
    ok.

-spec start_link() -> gen_server:start_ret().
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec put(reference(), opentelemetry:span_ctx(), map()) -> boolean().
put(Ref, SpanCtx, Attributes) ->
    Caller = self(),
    try
        ets:insert(?MODULE, {Ref, SpanCtx, Attributes, Caller}),
        ets:insert_new(?CALLERS, {Caller}) andalso gen_server:cast(?MODULE, {monitor, Caller}),
        true
    catch
        error:badarg -> false
    end.

-spec take(reference()) -> {opentelemetry:span_ctx(), map()} | undefined.
take(Ref) ->
    try ets:take(?MODULE, Ref) of
        [{Ref, SpanCtx, Attributes, _Caller}] -> {SpanCtx, Attributes};
        [] -> undefined
    catch
        error:badarg -> undefined
    end.

-spec started() -> boolean().
started() ->
    ets:whereis(?MODULE) =/= undefined andalso whereis(?MODULE) =/= undefined.

init([]) ->
    ets:foldl(fun({Caller}, ok) -> monitor(process, Caller), ok end, ok, ?CALLERS),
    {ok, #{}}.

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast({monitor, Caller}, State) ->
    monitor(process, Caller),
    {noreply, State};
handle_cast(_Request, State) ->
    {noreply, State}.

handle_info({'DOWN', _Monitor, process, Caller, _Reason}, State) ->
    ets:delete(?CALLERS, Caller),
    Refs = ets:select(?MODULE, [{{'$1', '_', '_', Caller}, [], ['$1']}]),
    lists:foreach(fun(Ref) -> end_orphan(ets:take(?MODULE, Ref)) end, Refs),
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

end_orphan([{_Ref, SpanCtx, _Attributes, _Caller}]) ->
    otel_span:set_attribute(SpanCtx, 'error.type', <<"_OTHER">>),
    otel_span:set_status(SpanCtx, opentelemetry:status(error, <<"_OTHER">>)),
    otel_span:end_span(SpanCtx);
end_orphan([]) ->
    ok.
