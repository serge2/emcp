-module(emcp_app).
-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    logger:info("MCP Framework application starting..."),
    ets:new(mcp_sessions,[named_table, public, set]),
    emcp_sup:start_link().

stop(_State) ->
    logger:info("MCP application stopping..."),
    ets:delete(mcp_sessions),
    ok.
