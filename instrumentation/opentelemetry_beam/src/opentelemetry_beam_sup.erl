-module(opentelemetry_beam_sup).

-behaviour(supervisor).

-export([start_link/0, init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    {ok, {#{strategy => one_for_one},
          [#{id => opentelemetry_beam_scheduler,
             start => {opentelemetry_beam_scheduler, start_link, []}}
           | system_monitor_child(opentelemetry_beam_system_monitor:options())]}}.

system_monitor_child([]) ->
    [];
system_monitor_child(Options) ->
    [#{id => opentelemetry_beam_system_monitor,
       start => {opentelemetry_beam_system_monitor, start_link, [Options]}}].
