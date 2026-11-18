-module(opentelemetry_beam_SUITE).

-compile(export_all).
-compile(nowarn_export_all).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("opentelemetry_experimental/include/otel_metrics.hrl").

all() ->
    [
        counts_against_limits,
        memory_by_type_and_state,
        scheduler_utilization,
        longest_message_queue
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
