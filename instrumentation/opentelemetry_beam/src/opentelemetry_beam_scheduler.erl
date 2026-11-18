-module(opentelemetry_beam_scheduler).

-behaviour(gen_server).

-export([start_link/0, utilization/0]).
-export([init/1, handle_call/3, handle_cast/2]).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% Share of time the normal and dirty CPU schedulers were busy since the previous call.
utilization() ->
    gen_server:call(?MODULE, utilization).

%% scheduler_wall_time stays on only while the process that turned it on is alive.
init([]) ->
    erlang:system_flag(scheduler_wall_time, true),
    {ok, scheduler:sample()}.

handle_call(utilization, _From, Previous) ->
    Sample = scheduler:sample(),
    {total, Utilization, _Percent} = lists:keyfind(total, 1, scheduler:utilization(Previous, Sample)),
    {reply, Utilization, Sample}.

handle_cast(_Request, State) ->
    {noreply, State}.
