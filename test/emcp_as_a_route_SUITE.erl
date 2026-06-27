-module(emcp_as_a_route_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-compile([export_all, nowarn_export_all]).

all() -> [
    initialize_test,
    tools_call_echo_test,
    cleanup_test
].

%% Common test suite for emcp framework using the example MCP implementation from README
%% The main target of the test is to ensure that the emcp framework can be started and
%% used as a route in a larger Cowboy application, and that the example MCP implementation
%% works correctly.

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(emcp),
    Port = find_free_port(),
    ?assert(is_integer(Port)),
    Name = list_to_atom("emcp_ct_" ++ integer_to_list(Port)),
    ?assert(start_cowboy_listener(Name, Port)), %% listener with demo api key for tests
    Url = lists:flatten(io_lib:format("http://127.0.0.1:~p/mcp", [Port])),
    httpc:set_options([{max_keep_alive_length, 0}, {max_sessions, 10}]), %% avoid requests piplining
    [{port, Port}, {listener, Name}, {url, Url} | Config].

end_per_suite(Config) ->
    Name = cfg_get(Config, listener),
    cowboy:stop_listener(Name).
    

init_per_testcase(_TestCase, Config) ->
    Url = cfg_get(Config, url),
    InitReq = jsx:encode(#{<<"jsonrpc">> => <<"2.0">>, <<"id">> => 1, <<"method">> => <<"initialize">>, <<"params">> => #{}}),
    {ok, {{_Prot, 200, _}, Headers, _Body}} = httpc:request(post, {Url, [{"x-api-key", "demo"}], "application/json", InitReq}, [], [{body_format, binary}]),
    {ok, Sess} = find_header_case_insensitive(Headers, "mcp-session-id"),
    Notif = jsx:encode(#{<<"jsonrpc">> => <<"2.0">>, <<"method">> => <<"notifications/initialized">>}),
    HeadersNotif = [{"x-api-key", "demo"}, {"mcp-session-id", Sess}],
    {ok, {{_Prot2, 202, _}, _H2, _B2}} = httpc:request(post, {Url, HeadersNotif, "application/json", Notif}, [], [{body_format, binary}]),
    [{session, Sess} | Config].

% The cleamup_test case will delete the session, so we only need to do this for other test cases
end_per_testcase(cleanup_test, _Config) ->
    ok;

end_per_testcase(_TestCase, Config) ->
    Url = cfg_get(Config, url),
    Sess = cfg_get(Config, session),
    {ok, {{_P,200,_}, _H, _B}} = httpc:request(delete, {Url, [{"x-api-key", "demo"}, {"mcp-session-id", Sess}]}, [], [{body_format, binary}]),
    ok.

%% Test cases

initialize_test(Config) ->
    Url = cfg_get(Config, url),
    InitReq = jsx:encode(#{<<"jsonrpc">> => <<"2.0">>, <<"id">> => 1, <<"method">> => <<"initialize">>, <<"params">> => #{}}),
    {ok, {{_Prot, 200, _}, Headers, Body}} = httpc:request(post, {Url, [{"x-api-key", "demo"}], "application/json", InitReq}, [], [{body_format, binary}]),
    {ok, Sess} = find_header_case_insensitive(Headers, "mcp-session-id"),
    Resp = jsx:decode(Body, [return_maps]),
    ?assert(is_map(maps:get(<<"result">>, Resp, #{}))),
    %% send notification from client that initialization is complete
    Notif = jsx:encode(#{<<"jsonrpc">> => <<"2.0">>, <<"method">> => <<"notifications/initialized">>}),
    HeadersNotif = [{"x-api-key", "demo"}, {"mcp-session-id", Sess}],
    {ok, {{_Prot2, 202, _}, _H2, _B2}} = httpc:request(post, {Url, HeadersNotif, "application/json", Notif}, [], [{body_format, binary}]).


tools_call_echo_test(Config) ->
    Url = cfg_get(Config, url),
    Sess = cfg_get(Config, session),
    CallReq = jsx:encode(#{<<"jsonrpc">> => <<"2.0">>, <<"id">> => 3, <<"method">> => <<"tools/call">>,
                           <<"params">> => #{ <<"name">> => <<"echo">>, <<"arguments">> => #{ <<"message">> => <<"Hello CT">> } } }),
    HeadersCall = [{"x-api-key", "demo"}, {"mcp-session-id", Sess}],
    {ok, {{_P,200,_}, _H3, BodyCall}} = httpc:request(post, {Url, HeadersCall, "application/json", CallReq}, [], [{body_format, binary}]),
    RespCall = jsx:decode(BodyCall, [return_maps]),
    ResultCall = maps:get(<<"result">>, RespCall),
    Content = maps:get(<<"content">>, ResultCall),
    ?assertEqual(<<"Hello CT">>, maps:get(<<"text">>, Content)).


cleanup_test(Config) ->
    ct:log("cleanup_test Config: ~p~n", [Config]),
    Url = cfg_get(Config, url),
    Sess = cfg_get(Config, session),    
    {ok, {{_P,200,_}, _H, _B}} = httpc:request(delete, {Url, [{"x-api-key", "demo"}, {"mcp-session-id", Sess}]}, [], [{body_format, binary}]).

%% Helpers

cfg_get(Config, Key) ->
    {Key, Val} = lists:keyfind(Key, 1, Config),
    Val.

find_free_port() ->
    {ok, Socket} = gen_tcp:listen(0, [{ip, {127, 0, 0, 1}}]),
    {ok, {_IP, Port}} = inet:sockname(Socket),
    gen_tcp:close(Socket),
    Port.

start_cowboy_listener(Name, Port) ->
    try
        %% Start with a custom cowboy entity with a demo API key so tests can authenticate
        Allowed = [unicode:characters_to_binary("demo")],
        Dispatch = cowboy_router:compile([
            {'_', [emcp:cowboy_route("/mcp", test_mcp, Allowed, #{})]}
        ]),

        {ok, _} = cowboy:start_clear(
            Name,
            [{port, Port}, {ip, {127,0,0,1}}],
            #{env => #{dispatch => Dispatch}}
        ),
        true
    catch _:_ ->
        false
    end.


%% Ensure header name/values as binaries for cowboy/httpc compatibility
header_binary(V) when is_binary(V) -> V;
header_binary(V) when is_list(V) -> unicode:characters_to_binary(V).


find_header_case_insensitive(Headers, Name) when is_list(Headers) ->
    NameLower = string:to_lower(Name),
    case lists:foldl(fun({K,V}, Acc) ->
                         case Acc of
                             {ok,_} -> Acc;
                             _ -> case string:to_lower(K) == NameLower of
                                      true -> {ok, header_binary(V)};
                                      false -> Acc
                                  end
                         end
                     end, false, Headers) of
        false -> {error, not_found};
        Res -> Res
    end.
