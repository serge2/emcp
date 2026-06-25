-module(emcp_sup).
-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).
-export([start_session/2]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

start_session(SessionId, McpInfo) ->
    supervisor:start_child(?MODULE, [SessionId, McpInfo]).

init([]) ->
    Child = #{
        id => emcp_session,
        start => {emcp_session, start_link, []},
        restart => temporary,
        shutdown => 5000,
        type => worker,
        modules => [emcp_session]},

    SupFlags = #{
        strategy => simple_one_for_one,
        intensity => 5,
        period => 10},

    {ok, {SupFlags, [Child]}}.
