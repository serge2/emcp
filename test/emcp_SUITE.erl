-module(emcp_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-compile(export_all).

all() -> [
    initialize_test,
    invalid_api_key_test,
    invalid_session_test,
    auth_bearer_header_test,
    missing_api_key_test,
    missing_session_test,
    tools_list_test,
    tools_call_echo_test,
    tools_call_sleep_test,
    sleep_cancel_test,
    resources_list_test,
    resources_read_test,
    prompts_list_test,
    prompts_get_test,
    accept_header_sse_test,
    ping_test,
    cleanup_test
].

%% Common test suite for emcp framework using the example MCP implementation from README

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(emcp),
    Port = find_free_port(18100, 18200),
    ?assert(is_integer(Port)),
    Name = list_to_atom("emcp_ct_" ++ integer_to_list(Port)),
    ?assert(start_emcp_listener(Name, Port)), %% listener with demo api key for tests
    Url = lists:flatten(io_lib:format("http://127.0.0.1:~p/mcp", [Port])),
    httpc:set_options([{max_keep_alive_length, 0}, {max_sessions, 10}]), %% avoid requests piplining
    [{port, Port}, {listener, Name}, {url, Url} | Config].

end_per_suite(Config) ->
    case lists:keyfind(listener, 1, Config) of
        {listener, Name} -> catch emcp:stop(Name), ok;
        _ -> ok
    end.
    

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

invalid_api_key_test(Config) ->
    Url = cfg_get(Config, url),
    %% Send POST initialize with bad API key and expect 401 plain/text body
    InitReq = jsx:encode(#{<<"jsonrpc">> => <<"2.0">>, <<"id">> => 1234, <<"method">> => <<"initialize">>, <<"params">> => #{}}),
    {ok, {{_P,401,_}, _H, Body}} = httpc:request(post, {Url, [{"x-api-key", "wrong"}], "application/json", InitReq}, [], [{body_format, binary}]),
    ?assertEqual(<<"invalid_api_key">>, Body).

invalid_session_test(Config) ->
    Url = cfg_get(Config, url),
    %% Use valid API key but invalid session id
    HeadersBadSess = [{"x-api-key", "demo"}, {"mcp-session-id", "does-not-exist"}],
    ToolsReq = jsx:encode(#{<<"jsonrpc">> => <<"2.0">>, <<"id">> => 999, <<"method">> => <<"tools/list">>, <<"params">> => #{}}),
    {ok, {{_P,400,_}, _H, Body}} = httpc:request(post, {Url, HeadersBadSess, "application/json", ToolsReq}, [], [{body_format, binary}]),
    Resp = jsx:decode(Body, [return_maps]),
    Error = maps:get(<<"error">>, Resp),
    ?assertEqual(-32001, maps:get(<<"code">>, Error)),
    ?assertEqual(<<"Invalid session">>, maps:get(<<"message">>, Error)).

%% Test: Authorization header with Bearer token should work as API key
auth_bearer_header_test(Config) ->
    Url = cfg_get(Config, url),
    Sess = cfg_get(Config, session),
    InitReq = jsx:encode(#{<<"jsonrpc">> => <<"2.0">>, <<"id">> => 4242, <<"method">> => <<"tools/list">>, <<"params">> => #{}}),
    Headers = [{"authorization", "Bearer demo"}, {"mcp-session-id", Sess}],
    {ok, {{_P,200,_}, _H, Body}} = httpc:request(post, {Url, Headers, "application/json", InitReq}, [], [{body_format, binary}]),
    Resp = jsx:decode(Body, [return_maps]),
    ?assert(is_map(maps:get(<<"result">>, Resp, #{}))).

missing_api_key_test(Config) ->    
    Url = cfg_get(Config, url),
    %% send initialize without any API key header
    InitReq = jsx:encode(#{<<"jsonrpc">> => <<"2.0">>, <<"id">> => 4321, <<"method">> => <<"initialize">>, <<"params">> => #{}}),
    {ok, {{_P,401,_}, _H, Body}} = httpc:request(post, {Url, [], "application/json", InitReq}, [], [{body_format, binary}]),
    ?assertEqual(<<"missing_api_key">>, Body).

missing_session_test(Config) ->
    Url = cfg_get(Config, url),
    %% send tools/list with API key but no session header
    ToolsReq = jsx:encode(#{<<"jsonrpc">> => <<"2.0">>, <<"id">> => 556, <<"method">> => <<"tools/list">>, <<"params">> => #{}}),
    {ok, {{_P,400,_}, _H, Body}} = httpc:request(post, {Url, [{"x-api-key","demo"}], "application/json", ToolsReq}, [], [{body_format, binary}]),
    Resp = jsx:decode(Body, [return_maps]),
    Error = maps:get(<<"error">>, Resp),
    ?assertEqual(-32001, maps:get(<<"code">>, Error)),
    ?assertEqual(<<"Invalid session">>, maps:get(<<"message">>, Error)).

tools_list_test(Config) ->
    Url = cfg_get(Config, url),
    Sess = cfg_get(Config, session),
    ToolsReq = jsx:encode(#{<<"jsonrpc">> => <<"2.0">>, <<"id">> => 2, <<"method">> => <<"tools/list">>, <<"params">> => #{}}),
    HeadersTools = [{"x-api-key", "demo"}, {"mcp-session-id", Sess}],
    {ok, {{_P,200,_}, _H2, BodyTools}} = httpc:request(post, {Url, HeadersTools, "application/json", ToolsReq}, [], [{body_format, binary}]),
    RespTools = jsx:decode(BodyTools, [return_maps]),
    Tools = maps:get(<<"tools">>, maps:get(<<"result">>, RespTools, #{}), []),
    ?assert(lists:any(fun(M) -> maps:get(<<"name">>, M) == <<"echo">> end, Tools)).

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

tools_call_sleep_test(Config) ->
    Url = cfg_get(Config, url),
    Sess = cfg_get(Config, session),
    CallReq = jsx:encode(#{<<"jsonrpc">> => <<"2.0">>, <<"id">> => 8, <<"method">> => <<"tools/call">>,
                           <<"params">> => #{ <<"name">> => <<"sleep">>, <<"arguments">> => #{ <<"duration_ms">> => 50 } } }),
    HeadersCall = [{"x-api-key", "demo"}, {"mcp-session-id", Sess}],
    {ok, {{_P,200,_}, _H3, BodyCall}} = httpc:request(post, {Url, HeadersCall, "application/json", CallReq}, [], [{body_format, binary}]),
    RespCall = jsx:decode(BodyCall, [return_maps]),
    ResultCall = maps:get(<<"result">>, RespCall),
    Content = maps:get(<<"content">>, ResultCall),
    ?assertEqual(50, maps:get(<<"slept_ms">>, Content)).

sleep_cancel_test(Config) ->
    Url = cfg_get(Config, url),
    Sess = cfg_get(Config, session),
    %% Start a long sleep asynchronously
    CallReq = jsx:encode(#{<<"jsonrpc">> => <<"2.0">>, <<"id">> => 9, <<"method">> => <<"tools/call">>,
                           <<"params">> => #{ <<"name">> => <<"sleep">>, <<"arguments">> => #{ <<"duration_ms">> => 2000 } } }),
    HeadersCall = [{"x-api-key", "demo"}, {"mcp-session-id", Sess}],
    {ok, ReqId} = httpc:request(post, {Url, HeadersCall, "application/json", CallReq}, [], [{body_format, binary}, {sync, false}, {receiver, self()}]),
    %% Give the worker a moment to start
    timer:sleep(100),
    %% Send cancellation notification for request id=9
    Notif = jsx:encode(#{<<"jsonrpc">> => <<"2.0">>, <<"method">> => <<"notifications/cancelled">>,
                        <<"params">> => #{ <<"requestId">> => 9, <<"reason">> => <<"test-cancel">>} }),
    HeadersNotif = [{"x-api-key", "demo"}, {"mcp-session-id", Sess}],
    logger:warning("Sending cancellation notification for request 9"),
    {ok, {{_P2,202,_}, _H2, _B2}} = httpc:request(post, {Url, HeadersNotif, "application/json", Notif}, [], [{body_format, binary}]),
    %% Attempt to receive the response; it should fail/timeout because worker was cancelled
    receive
        {http, {ReqId, Result}} ->
            ?assert(false, io_lib:format("Expected no response, but got: ~p", [Result]))
    after 2000 ->
            ok
    end,
    %% Ensure session still usable
    ToolsReq = jsx:encode(#{<<"jsonrpc">> => <<"2.0">>, <<"id">> => 10, <<"method">> => <<"tools/list">>, <<"params">> => #{}}),
    {ok, {{_P4,200,_}, _H4, BodyTools}} = httpc:request(post, {Url, HeadersCall, "application/json", ToolsReq}, [], [{body_format, binary}]),
    RespTools = jsx:decode(BodyTools, [return_maps]),
    Tools = maps:get(<<"tools">>, maps:get(<<"result">>, RespTools, #{}), []),
    ?assert(lists:any(fun(M) -> maps:get(<<"name">>, M) == <<"sleep">> end, Tools)).

resources_list_test(Config) ->
    Url = cfg_get(Config, url),
    Sess = cfg_get(Config, session),
    Req = jsx:encode(#{<<"jsonrpc">> => <<"2.0">>, <<"id">> => 5, <<"method">> => <<"resources/list">>, <<"params">> => #{}}),
    Headers = [{"x-api-key", "demo"}, {"mcp-session-id", Sess}],
    {ok, {{_P,200,_}, _H, Body}} = httpc:request(post, {Url, Headers, "application/json", Req}, [], [{body_format, binary}]),
    Resp = jsx:decode(Body, [return_maps]),
    Resources = maps:get(<<"resources">>, maps:get(<<"result">>, Resp, #{}), []),
    ?assert(is_list(Resources)),
    ?assert(lists:any(fun(R) -> maps:get(<<"uri">>, R, <<"">>) == <<"resource://sys/datetime">> end, Resources)).

resources_read_test(Config) ->
    ct:log("resources_read_test Config: ~p~n", [Config]),
    Url = cfg_get(Config, url),
    Sess = cfg_get(Config, session),
    Req = jsx:encode(#{<<"jsonrpc">> => <<"2.0">>, <<"id">> => 4, <<"method">> => <<"resources/read">>, <<"params">> => #{<<"uri">> => <<"resource://sys/datetime">>} }),
    HeadersRead = [{"x-api-key", "demo"}, {"mcp-session-id", Sess}],
    {ok, {{_P,200,_}, _H, Body}} = httpc:request(post, {Url, HeadersRead, "application/json", Req}, [], [{body_format, binary}]),
    Resp = jsx:decode(Body, [return_maps]),
    ?assertMatch(#{<<"result">> := #{<<"contents">> := [_|_]}}, Resp).

prompts_list_test(Config) ->
    Url = cfg_get(Config, url),
    Sess = cfg_get(Config, session),
    Req = jsx:encode(#{<<"jsonrpc">> => <<"2.0">>, <<"id">> => 6, <<"method">> => <<"prompts/list">>, <<"params">> => #{}}),
    Headers = [{"x-api-key", "demo"}, {"mcp-session-id", Sess}],
    {ok, {{_P,200,_}, _H, Body}} = httpc:request(post, {Url, Headers, "application/json", Req}, [], [{body_format, binary}]),
    Resp = jsx:decode(Body, [return_maps]),
    Prompts = maps:get(<<"prompts">>, maps:get(<<"result">>, Resp, #{}), []),
    ?assert(is_list(Prompts)),
    ?assert(lists:any(fun(P) -> maps:get(<<"name">>, P, <<"">>) == <<"code_review">> end, Prompts)).

prompts_get_test(Config) ->
    Url = cfg_get(Config, url),
    Sess = cfg_get(Config, session),
    Req = jsx:encode(#{<<"jsonrpc">> => <<"2.0">>, <<"id">> => 11, <<"method">> => <<"prompts/get">>, <<"params">> => #{<<"name">> => <<"code_review">>, <<"arguments">> => #{<<"code">> => <<"print(\'hello\')">>} } }),
    Headers = [{"x-api-key", "demo"}, {"mcp-session-id", Sess}],
    {ok, {{_P,200,_}, _H, Body}} = httpc:request(post, {Url, Headers, "application/json", Req}, [], [{body_format, binary}]),
    Resp = jsx:decode(Body, [return_maps]),
    Result = maps:get(<<"result">>, Resp),
    ?assertEqual(<<"Code review prompt">>, maps:get(<<"description">>, Result)),
    Messages = maps:get(<<"messages">>, Result, []),
    ?assert(lists:any(fun(M) -> maps:get(<<"role">>, M, <<"">>) == <<"user">> end, Messages)).

accept_header_sse_test(Config) ->
    Url = cfg_get(Config, url),
    Sess = cfg_get(Config, session),
    Req = jsx:encode(#{<<"jsonrpc">> => <<"2.0">>, <<"id">> => 21, <<"method">> => <<"tools/list">>, <<"params">> => #{} }),
    HeadersBase = [{"x-api-key", "demo"}, {"mcp-session-id", Sess}],
    Accepts = ["application/json;q=0.3, text/event-stream; q=0.9",
               "text/event-stream; q=0.2, application/json; q=1"],
    lists:foreach(fun(Accept) ->
        Headers = [{"accept", Accept} | HeadersBase],
        {ok, {{_P,200,_}, H, Body}} = httpc:request(post, {Url, Headers, "application/json", Req}, [], [{body_format, binary}]),
        {ok, ContentType} = find_header_case_insensitive(H, "content-type"),
        ?assertEqual(<<"text/event-stream">>, string:lowercase(unicode:characters_to_binary(ContentType))),
        ?assertMatch(<<"data: ", _/binary>>, Body)
    end, Accepts).

ping_test(Config) ->
    Url = cfg_get(Config, url),
    Sess = cfg_get(Config, session),
    Req = jsx:encode(#{<<"jsonrpc">> => <<"2.0">>, <<"id">> => 7, <<"method">> => <<"ping">>, <<"params">> => #{}}),
    Headers = [{"x-api-key", "demo"}, {"mcp-session-id", Sess}],
    {ok, {{_P,200,_}, _H, Body}} = httpc:request(post, {Url, Headers, "application/json", Req}, [], [{body_format, binary}]),
    Resp = jsx:decode(Body, [return_maps]),
    Result = maps:get(<<"result">>, Resp, #{}),
    ?assertEqual(#{}, Result).

cleanup_test(Config) ->
    ct:log("cleanup_test Config: ~p~n", [Config]),
    Url = cfg_get(Config, url),
    Sess = cfg_get(Config, session),    
    {ok, {{_P,200,_}, _H, _B}} = httpc:request(delete, {Url, [{"x-api-key", "demo"}, {"mcp-session-id", Sess}]}, [], [{body_format, binary}]),
    catch emcp:stop(cfg_get(Config, listener)).

%% Helpers

add_session(Config, Sess) ->
    lists:keystore(session, 1, Config, {session, Sess}).

cfg_get(Config, Key) ->
    {Key, Val} = lists:keyfind(Key, 1, Config),
    Val.

find_free_port(From, To) when From =< To ->
    case try_start_any(From) of
        {ok, Port} -> Port;
        error -> find_free_port(From + 1, To)
    end;
find_free_port(_, _) ->
    ct:fail("No free port found in range").

try_start_any(Port) ->
    Name = list_to_atom("emcp_ct_" ++ integer_to_list(Port)),
    try
        emcp:start(Name, test_mcp, {127,0,0,1}, Port, "/mcp", false, [], #{root_dir => "/tmp"}),
        emcp:stop(Name),
        {ok, Port}
    catch _:_ ->
        error
    end.

start_emcp_listener(Name, Port) ->
    try
        %% Start with a demo API key so tests can authenticate
        Allowed = [unicode:characters_to_binary("demo")],
        {ok, _} = emcp:start(Name, test_mcp, {127,0,0,1}, Port, "/mcp", false, Allowed, #{root_dir => "/tmp"}),
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
