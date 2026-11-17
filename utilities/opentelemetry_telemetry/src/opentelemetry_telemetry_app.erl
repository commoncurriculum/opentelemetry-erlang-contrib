-module(opentelemetry_telemetry_app).

-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    opentelemetry_telemetry_sup:start_link().

stop(_State) ->
    ok.
