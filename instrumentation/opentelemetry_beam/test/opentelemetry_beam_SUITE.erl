-module(opentelemetry_beam_SUITE).

-compile(export_all).
-compile(nowarn_export_all).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("opentelemetry_experimental/include/otel_metrics.hrl").
-include_lib("opentelemetry_api/include/opentelemetry.hrl").
-include_lib("opentelemetry/include/otel_span.hrl").

all() ->
    [
        counts_against_limits,
        memory_by_type_and_state,
        scheduler_utilization,
        longest_message_queue,
        persistent_terms,
        large_heap,
        long_gc,
        long_schedule,
        busy_port,
        long_message_queue,
        max_heap_size
    ].

init_per_suite(Config) ->
    application:set_env(opentelemetry_experimental, readers, [
        #{module => otel_metric_reader,
          config => #{exporter => {otel_metric_exporter_pid, self()}}}
    ]),
    {ok, _} = application:ensure_all_started(opentelemetry_experimental),
    {ok, _} = application:ensure_all_started(opentelemetry_beam),
    Config.

end_per_suite(_Config) ->
    application:stop(opentelemetry_beam),
    application:stop(opentelemetry_experimental).

init_per_testcase(_, Config) ->
    ok = application:stop(opentelemetry_experimental),
    application:set_env(opentelemetry_experimental, readers, [
        #{module => otel_metric_reader,
          config => #{exporter => {otel_metric_exporter_pid, self()}}}
    ]),
    {ok, _} = application:ensure_all_started(opentelemetry_experimental),
    ok = opentelemetry_beam_metrics:setup(),
    Config.

end_per_testcase(_, _Config) ->
    ok.

counts_against_limits(_Config) ->
    Metrics = collect(),
    lists:foreach(
      fun({Count, Limit}) ->
              CountValue = single_value(Count, Metrics),
              LimitValue = single_value(Limit, Metrics),
              ?assert(CountValue >= 1 andalso CountValue =< LimitValue, {Count, CountValue, LimitValue})
      end,
      [{'beam.atom.count', 'beam.atom.limit'},
       {'beam.ets.count', 'beam.ets.limit'},
       {'beam.port.count', 'beam.port.limit'},
       {'beam.process.count', 'beam.process.limit'}]),
    ?assertEqual(1, single_value('beam.node.count', Metrics)),
    ok.

memory_by_type_and_state(_Config) ->
    Metrics = collect(),
    ?assertEqual([atom, binary, code, ets, other],
                 lists:sort([maps:get('beam.memory.type', A) || {_, A} <- points('beam.memory.system', Metrics)])),
    ?assertEqual([processes, system],
                 lists:sort([maps:get('beam.memory.type', A) || {_, A} <- points('beam.memory.allocated', Metrics)])),
    ?assertEqual([free, used],
                 lists:sort([maps:get('beam.memory.state', A) || {_, A} <- points('beam.memory.processes', Metrics)])),
    ok.

scheduler_utilization(_Config) ->
    Utilization = single_value('beam.scheduler.utilization', collect()),
    ?assert(Utilization >= 0 andalso Utilization =< 1, Utilization),
    ok.

longest_message_queue(_Config) ->
    Pid = spawn_link(fun() -> receive stop -> ok end end),
    true = register(opentelemetry_beam_blocked, Pid),
    [Pid ! {filler, N} || N <- lists:seq(1, 100000)],
    [{Length, Attributes}] = points('beam.process.message_queue_len.max', collect()),
    Pid ! stop,
    ?assert(Length >= 100000, Length),
    ?assertEqual(#{'beam.process.registered_name' => <<"opentelemetry_beam_blocked">>,
                   'beam.process.initial_call' => <<"erlang:apply/2">>},
                 Attributes),
    ok.

persistent_terms(_Config) ->
    persistent_term:put({?MODULE, persistent_terms}, lists:seq(1, 1000)),
    Metrics = collect(),
    persistent_term:erase({?MODULE, persistent_terms}),
    ?assert(single_value('beam.persistent_term.count', Metrics) >= 1),
    ?assert(single_value('beam.persistent_term.memory', Metrics) > 1000),
    ok.

large_heap(_Config) ->
    start_system_monitor(large_heap_bytes, 20000000),
    Self = self(),
    Pid = spawn_link(fun() ->
                             true = register(opentelemetry_beam_large, self()),
                             Parent = otel_tracer:start_span(opentelemetry:get_tracer(), <<"parent">>, #{}),
                             otel_tracer:set_current_span(Parent),
                             Self ! {parent, Parent},
                             Big = lists:seq(1, 4000000),
                             receive stop -> length(Big) end
                     end),
    Parent = receive {parent, P} -> P end,
    {Attributes, Links} = receive_span(<<"beam.process.large_heap">>),
    Pid ! stop,
    stop_system_monitor(large_heap_bytes),
    ?assertEqual([{Parent#span_ctx.trace_id, Parent#span_ctx.span_id}],
                 [{TraceId, SpanId} || #link{trace_id = TraceId, span_id = SpanId} <- Links]),
    ?assertMatch(#{'beam.process.registered_name' := <<"opentelemetry_beam_large">>,
                   'beam.process.initial_call' := <<"erlang:apply/2">>,
                   'beam.process.message_queue_len' := 0},
                 Attributes),
    ?assert(maps:get('beam.process.memory', Attributes) > 20000000),
    ?assertEqual(list_to_binary(pid_to_list(Pid)), maps:get('beam.process.pid', Attributes)),
    ?assertMatch(<<_/binary>>, maps:get('code.stacktrace', Attributes)),
    ok.

long_gc(_Config) ->
    start_system_monitor(long_gc_ms, 1),
    Pid = spawn_link(fun() -> collect_large_heap(opentelemetry_beam_long_gc) end),
    {Attributes, _} = receive_span(<<"beam.process.long_gc">>),
    Pid ! stop,
    stop_system_monitor(long_gc_ms),
    ?assertMatch(#{'beam.process.registered_name' := <<"opentelemetry_beam_long_gc">>}, Attributes),
    ?assert(maps:get('beam.process.gc.duration', Attributes) >= 1),
    ok.

long_schedule(_Config) ->
    start_system_monitor(long_schedule_ms, 1),
    Pid = spawn_link(fun() ->
                             true = register(opentelemetry_beam_long_schedule, self()),
                             Table = ets:new(?MODULE, []),
                             true = ets:insert(Table, [{N} || N <- lists:seq(1, 3000000)]),
                             receive stop -> ok end
                     end),
    {Attributes, _} = receive_span(<<"beam.process.long_schedule">>),
    Pid ! stop,
    stop_system_monitor(long_schedule_ms),
    ?assertMatch(#{'beam.process.registered_name' := <<"opentelemetry_beam_long_schedule">>}, Attributes),
    ?assert(maps:get('beam.process.schedule.duration', Attributes) >= 1),
    ok.

busy_port(_Config) ->
    start_system_monitor(busy_port, true),
    Self = self(),
    Pid = spawn(fun() ->
                        true = register(opentelemetry_beam_busy_port, self()),
                        Port = open_port({spawn, "sleep 30"}, [binary, {busy_limits_port, {1024, 2048}}]),
                        Self ! {port, Port},
                        [port_command(Port, binary:copy(<<1>>, 100000)) || _ <- lists:seq(1, 10)]
                end),
    Port = receive {port, P} -> P end,
    {Attributes, _} = receive_span(<<"beam.process.busy_port">>),
    exit(Pid, kill),
    catch port_close(Port),
    stop_system_monitor(busy_port),
    ?assertMatch(#{'beam.process.registered_name' := <<"opentelemetry_beam_busy_port">>,
                   'beam.port.name' := <<"sleep 30">>},
                 Attributes),
    ?assertEqual(list_to_binary(erlang:port_to_list(Port)), maps:get('beam.port.id', Attributes)),
    ok.

long_message_queue(_Config) ->
    case catch erlang:system_monitor(self(), [{long_message_queue, {1, 2}}]) of
        {'EXIT', {badarg, _}} ->
            {skip, long_message_queue_unsupported};
        _ ->
            erlang:system_monitor(undefined),
            start_system_monitor(long_message_queue, {100, 1000}),
            Pid = spawn_link(fun() ->
                                     true = register(opentelemetry_beam_long_queue, self()),
                                     receive stop -> ok end
                             end),
            [Pid ! {filler, N} || N <- lists:seq(1, 2000)],
            {Attributes, _} = receive_span(<<"beam.process.long_message_queue">>),
            Pid ! stop,
            stop_system_monitor(long_message_queue),
            ?assertMatch(#{'beam.process.registered_name' := <<"opentelemetry_beam_long_queue">>}, Attributes),
            ?assert(maps:get('beam.process.message_queue_len', Attributes) >= 1000),
            ok
    end.

max_heap_size(_Config) ->
    case opentelemetry_beam_system_monitor:supports_shared_binaries() of
        false ->
            {skip, include_shared_binaries_unsupported};
        true ->
            Before = erlang:system_info(max_heap_size),
            ok = logger:add_handler(max_heap_size_test, ?MODULE, #{config => #{pid => self()}}),
            start_system_monitor(max_heap_size_bytes, 10000000),
            Pid = spawn_link(fun() ->
                                     true = register(opentelemetry_beam_binaries, self()),
                                     Binaries = [binary:copy(<<1>>, 1000000) || _ <- lists:seq(1, 20)],
                                     erlang:garbage_collect(),
                                     receive stop -> length(Binaries) end
                             end),
            {Attributes, _} = receive_span(<<"beam.process.max_heap_size">>),
            receive
                {logged, {Format, [Pid | _]}} ->
                    ?assertNotEqual(nomatch, string:find(Format, "maximum heap size reached"))
            after 5000 ->
                    ct:fail(max_heap_size_not_logged)
            end,
            ok = logger:remove_handler(max_heap_size_test),
            Pid ! stop,
            stop_system_monitor(max_heap_size_bytes),
            ?assertMatch(#{'beam.process.registered_name' := <<"opentelemetry_beam_binaries">>,
                           'beam.process.max_heap_size' := 10000000},
                         Attributes),
            ?assert(maps:get('beam.process.binary.memory', Attributes) + maps:get('beam.process.memory', Attributes) > 10000000),
            ?assertEqual(Before, erlang:system_info(max_heap_size)),
            #{filters := Filters} = logger:get_primary_config(),
            ?assertNot(lists:keymember(opentelemetry_beam_max_heap_size, 1, Filters)),
            ok
    end.

log(#{msg := Msg}, #{config := #{pid := Pid}}) ->
    Pid ! {logged, Msg}.

collect_large_heap(Name) ->
    true = register(Name, self()),
    Big = lists:seq(1, 4000000),
    erlang:garbage_collect(),
    receive stop -> length(Big) end.

start_system_monitor(Key, Value) ->
    ok = application:stop(opentelemetry_beam),
    ok = application:stop(opentelemetry_experimental),
    ok = application:stop(opentelemetry),
    application:set_env(opentelemetry_beam, Key, Value),
    application:set_env(opentelemetry, processors,
                        [{otel_simple_processor, #{exporter => {otel_exporter_pid, self()}}}]),
    {ok, _} = application:ensure_all_started(opentelemetry_experimental),
    {ok, _} = application:ensure_all_started(opentelemetry_beam).

stop_system_monitor(Key) ->
    ok = application:stop(opentelemetry_beam),
    application:unset_env(opentelemetry_beam, Key),
    {ok, _} = application:ensure_all_started(opentelemetry_beam).

receive_span(Name) ->
    receive
        {span, #span{name = Name, attributes = Attributes, links = Links}} ->
            {otel_attributes:map(Attributes), otel_links:list(Links)}
    after 5000 ->
            ct:fail({no_span, Name})
    end.

collect() ->
    otel_meter_server:force_flush(),
    collect(#{}).

collect(Acc) ->
    receive
        {otel_metric, #metric{name = Name, data = Data}} ->
            collect(Acc#{Name => datapoints(Data)})
    after 500 ->
            Acc
    end.

datapoints(#sum{datapoints = Points}) -> [{V, A} || #datapoint{value = V, attributes = A} <- Points];
datapoints(#gauge{datapoints = Points}) -> [{V, A} || #datapoint{value = V, attributes = A} <- Points];
datapoints(_) -> [].

points(Name, Metrics) ->
    case maps:find(Name, Metrics) of
        {ok, Points} -> Points;
        error -> ct:fail({missing_metric, Name, maps:keys(Metrics)})
    end.

single_value(Name, Metrics) ->
    [{Value, #{}}] = points(Name, Metrics),
    Value.
