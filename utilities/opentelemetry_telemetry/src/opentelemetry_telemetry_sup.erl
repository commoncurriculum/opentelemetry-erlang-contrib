-module(opentelemetry_telemetry_sup).

-behaviour(supervisor).

-export([start_link/0, init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    Spans = #{id => otel_telemetry_spans, start => {otel_telemetry_spans, start_link, []}},
    {ok, {#{strategy => one_for_one}, [Spans]}}.
