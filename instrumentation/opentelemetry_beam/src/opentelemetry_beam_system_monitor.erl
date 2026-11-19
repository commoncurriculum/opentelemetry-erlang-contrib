-module(opentelemetry_beam_system_monitor).

-behaviour(gen_server).

-export([start_link/1, options/0, supports_shared_binaries/0, max_heap_size_filter/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(REPEAT_AFTER_MS, 60000).
-define(FILTER, opentelemetry_beam_max_heap_size).

start_link(Options) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, Options, []).

options() ->
    lists:flatmap(fun option/1, [large_heap_bytes, long_gc_ms, long_schedule_ms,
                                 busy_port, busy_dist_port, long_message_queue,
                                 max_heap_size_bytes]).

option(Key) ->
    case {Key, application:get_env(opentelemetry_beam, Key)} of
        {large_heap_bytes, {ok, Bytes}} when is_integer(Bytes), Bytes > 0 ->
            [{large_heap, Bytes div erlang:system_info(wordsize)}];
        {long_gc_ms, {ok, Ms}} when is_integer(Ms), Ms > 0 ->
            [{long_gc, Ms}];
        {long_schedule_ms, {ok, Ms}} when is_integer(Ms), Ms > 0 ->
            [{long_schedule, Ms}];
        {busy_port, {ok, true}} ->
            [busy_port];
        {busy_dist_port, {ok, true}} ->
            [busy_dist_port];
        {long_message_queue, {ok, {Disable, Enable}}}
          when is_integer(Disable), is_integer(Enable), Disable >= 0, Enable > Disable ->
            [{long_message_queue, {Disable, Enable}}];
        {max_heap_size_bytes, {ok, Bytes}} when is_integer(Bytes), Bytes > 0 ->
            [{max_heap_size, Bytes div erlang:system_info(wordsize)} || supports_shared_binaries()];
        _ ->
            []
    end.

%% Older VMs silently drop include_shared_binaries instead of rejecting it.
supports_shared_binaries() ->
    Self = self(),
    {Pid, Ref} = spawn_monitor(
                   fun() ->
                           _ = erlang:process_flag(max_heap_size, #{size => 0, include_shared_binaries => true}),
                           {max_heap_size, Flag} = erlang:process_info(self(), max_heap_size),
                           Self ! {self(), maps:get(include_shared_binaries, Flag, false)}
                   end),
    receive
        {Pid, Supported} ->
            erlang:demonitor(Ref, [flush]),
            Supported;
        {'DOWN', Ref, process, Pid, _} ->
            false
    end.

%% The VM allows one system monitor per node, and it is cleared when this process exits.
init(Options) ->
    process_flag(trap_exit, true),
    MaxHeapSize = [Option || {max_heap_size, _} = Option <- Options],
    install_system_monitor(Options -- MaxHeapSize),
    {ok, #{reported => #{}, max_heap_size => install_max_heap_size(MaxHeapSize)}}.

%% VMs before long_message_queue existed reject the whole option list.
install_system_monitor(Options) ->
    try
        erlang:system_monitor(self(), Options)
    catch
        error:badarg ->
            erlang:system_monitor(self(), lists:keydelete(long_message_queue, 1, Options))
    end.

%% Off-heap binaries only count toward max_heap_size, which reports through the logger on
%% every garbage collection over the limit. The filter turns those events into spans
%% instead of error log lines. The system default applies to processes spawned after this.
install_max_heap_size([{max_heap_size, Words}]) ->
    ok = logger:add_primary_filter(?FILTER, {fun ?MODULE:max_heap_size_filter/2, {self(), Words}}),
    erlang:system_flag(max_heap_size, #{size => Words, kill => false, error_logger => true,
                                        include_shared_binaries => true});
install_max_heap_size([]) ->
    undefined.

max_heap_size_filter(#{msg := {Format, [Pid, Words, _TotalHeapSize, false | _]}}, {Server, Words}) when is_pid(Pid) ->
    case string:find(Format, "maximum heap size reached") of
        nomatch ->
            ignore;
        _ ->
            Server ! {monitor, Pid, max_heap_size, Words},
            stop
    end;
max_heap_size_filter(_, _) ->
    ignore.

terminate(_Reason, #{max_heap_size := undefined}) ->
    ok;
terminate(_Reason, #{max_heap_size := Previous}) ->
    _ = erlang:system_flag(max_heap_size, Previous),
    _ = logger:remove_primary_filter(?FILTER),
    ok.

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(_Request, State) ->
    {noreply, State}.

%% A process over a threshold can trigger an event on every garbage collection or schedule.
handle_info({monitor, _Pid, long_message_queue, false}, State) ->
    {noreply, State};
handle_info({monitor, Subject, Event, Info}, #{reported := Reported} = State) ->
    Now = erlang:monotonic_time(millisecond),
    Recent = maps:filter(fun(_Key, At) -> Now - At < ?REPEAT_AFTER_MS end, Reported),
    case maps:is_key({Event, Subject}, Recent) of
        true ->
            {noreply, State#{reported := Recent}};
        false ->
            report(Event, Subject, Info),
            {noreply, State#{reported := Recent#{{Event, Subject} => Now}}}
    end;
handle_info(_Info, State) ->
    {noreply, State}.

report(Event, Subject, Info) ->
    try subject_attributes(Subject) of
        {Attributes, Links} ->
            Tracer = opentelemetry:get_application_tracer(?MODULE),
            SpanCtx = otel_tracer:start_span(otel_ctx:new(), Tracer,
                                             <<"beam.process.", (atom_to_binary(Event))/binary>>,
                                             #{attributes => maps:merge(Attributes, event_attributes(Event, Info)),
                                               links => Links}),
            _ = otel_span:end_span(SpanCtx),
            ok;
        undefined ->
            ok
    catch
        _:_ -> ok
    end.

subject_attributes(Pid) when is_pid(Pid) ->
    case erlang:process_info(Pid, [registered_name, initial_call, dictionary, memory, binary,
                                   message_queue_len, current_stacktrace]) of
        [{registered_name, Name}, {initial_call, InitialCall}, {dictionary, Dictionary},
         {memory, Memory}, {binary, Binaries}, {message_queue_len, QueueLen},
         {current_stacktrace, Stacktrace}] ->
            {(opentelemetry_beam_metrics:process_attributes(Name, InitialCall, Dictionary))#{
                'beam.process.pid' => list_to_binary(pid_to_list(Pid)),
                'beam.process.memory' => Memory,
                'beam.process.binary.memory' => lists:sum([Size || {_, Size, _} <- Binaries]),
                'beam.process.message_queue_len' => QueueLen,
                'code.stacktrace' => format_stacktrace(Stacktrace)},
             opentelemetry:links([process_span_ctx(Dictionary)])};
        undefined ->
            undefined
    end;
subject_attributes(Port) when is_port(Port) ->
    {port_attributes(Port), []}.

event_attributes(long_gc, Info) ->
    #{'beam.process.gc.duration' => proplists:get_value(timeout, Info)};
event_attributes(long_schedule, Info) ->
    maps:merge(#{'beam.process.schedule.duration' => proplists:get_value(timeout, Info)},
               maps:from_list([{Key, format_location_mfa(Location)}
                               || {Key, Location} <- [{'beam.process.schedule.in', proplists:get_value(in, Info)},
                                                      {'beam.process.schedule.out', proplists:get_value(out, Info)}],
                                  Location =/= undefined]));
event_attributes(max_heap_size, Words) ->
    #{'beam.process.max_heap_size' => Words * erlang:system_info(wordsize)};
event_attributes(Busy, Port) when Busy =:= busy_port; Busy =:= busy_dist_port ->
    port_attributes(Port);
event_attributes(_, _) ->
    #{}.

port_attributes(Port) ->
    Attributes = #{'beam.port.id' => list_to_binary(erlang:port_to_list(Port))},
    case erlang:port_info(Port, name) of
        {name, Name} -> Attributes#{'beam.port.name' => list_to_binary(Name)};
        undefined -> Attributes
    end.

process_span_ctx(Dictionary) ->
    case proplists:get_value('$__current_otel_ctx', Dictionary) of
        undefined -> undefined;
        Ctx -> otel_tracer:current_span_ctx(Ctx)
    end.

format_location_mfa({M, F, A}) ->
    iolist_to_binary(io_lib:format("~ts:~ts/~b", [M, F, A]));
format_location_mfa(Other) ->
    iolist_to_binary(io_lib:format("~0p", [Other])).

format_stacktrace(Stacktrace) ->
    iolist_to_binary(lists:join($\n, [format_frame(Frame) || Frame <- Stacktrace])).

format_frame({M, F, A, Location}) ->
    Arity = case A of
                N when is_integer(N) -> N;
                Args -> length(Args)
            end,
    io_lib:format("~ts:~ts/~b~ts", [M, F, Arity, format_location(Location)]).

format_location(Location) ->
    case {proplists:get_value(file, Location), proplists:get_value(line, Location)} of
        {File, Line} when File =/= undefined, Line =/= undefined -> io_lib:format(" (~ts:~b)", [File, Line]);
        _ -> ""
    end.
