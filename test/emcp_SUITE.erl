-module(emcp_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-compile(export_all).

all() -> [initialize_test, tools_list_test, tools_call_echo_test, resources_read_test, cleanup_test].

%% Common test suite for emcp framework using the example MCP implementation from README

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(emcp),
    Port = find_free_port(18100, 18200),
    ?assert(is_integer(Port)),
    Name = list_to_atom("emcp_ct_" ++ integer_to_list(Port)),
    ?assert(start_emcp_listener(Name, Port)), %% listener with demo api key for tests
    Url = lists:flatten(io_lib:format("http://127.0.0.1:~p/mcp", [Port])),
    Config ++ [{port, Port}, {listener, Name}, {url, Url}].

end_per_suite(Config) ->
    case lists:keyfind(listener, 1, Config) of
        {listener, Name} -> catch emcp:stop(Name), ok;
        _ -> ok
    end.
    

init_per_testcase(_TestCase, Config) ->
    Config.

end_per_testcase(_TestCase, Config) ->
    Config.

%% Test cases

initialize_test(Config) ->
    Url = cfg_get(Config, url),
    InitReq = jsx:encode(#{<<"jsonrpc">> => <<"2.0">>, <<"id">> => 1, <<"method">> => <<"initialize">>, <<"params">> => #{}}),
    {ok, {{_Prot, 200, _}, Headers, Body}} = httpc:request(post, {Url, [{"x-api-key", "demo"}], "application/json", InitReq}, [], [{body_format, binary}]),
    {ok, Sess} = find_header_case_insensitive(Headers, "mcp-session-id"),
    Resp = jsx:decode(Body, [return_maps]),
    ?assert(is_map(maps:get(<<"result">>, Resp, #{}))),
    {save_config, [{session, Sess}]}.

tools_list_test(Config) ->
    Url = cfg_get(Config, url),
    {initialize_test, SavedConfig} = proplists:get_value(saved_config, Config, []),
    Sess = cfg_get(SavedConfig, session),
    ToolsReq = jsx:encode(#{<<"jsonrpc">> => <<"2.0">>, <<"id">> => 2, <<"method">> => <<"tools/list">>, <<"params">> => #{}}),
    HeadersTools = [{"x-api-key", "demo"}, {"mcp-session-id", Sess}],
    {ok, {{_P,200,_}, _H2, BodyTools}} = httpc:request(post, {Url, HeadersTools, "application/json", ToolsReq}, [], [{body_format, binary}]),
    RespTools = jsx:decode(BodyTools, [return_maps]),
    Tools = maps:get(<<"tools">>, maps:get(<<"result">>, RespTools, #{}), []),
    ?assert(lists:any(fun(M) -> maps:get(<<"name">>, M) == <<"echo">> end, Tools)),
    {save_config, [{session, Sess}]}.

tools_call_echo_test(Config) ->
    Url = cfg_get(Config, url),
    {tools_list_test, SavedConfig} = proplists:get_value(saved_config, Config, []),
    Sess = cfg_get(SavedConfig, session),
    CallReq = jsx:encode(#{<<"jsonrpc">> => <<"2.0">>, <<"id">> => 3, <<"method">> => <<"tools/call">>,
                           <<"params">> => #{ <<"name">> => <<"echo">>, <<"arguments">> => #{ <<"message">> => <<"Hello CT">> } } }),
    HeadersCall = [{"x-api-key", "demo"}, {"mcp-session-id", Sess}],
    {ok, {{_P,200,_}, _H3, BodyCall}} = httpc:request(post, {Url, HeadersCall, "application/json", CallReq}, [], [{body_format, binary}]),
    RespCall = jsx:decode(BodyCall, [return_maps]),
    ResultCall = maps:get(<<"result">>, RespCall),
    Content = maps:get(<<"content">>, ResultCall),
    ?assertEqual(<<"Hello CT">>, maps:get(<<"text">>, Content)),
    {save_config, [{session, Sess}]}.

resources_read_test(Config) ->
    ct:log("resources_read_test Config: ~p~n", [Config]),
    Url = cfg_get(Config, url),
    {tools_call_echo_test, SavedConfig} = proplists:get_value(saved_config, Config, []),
    Sess = cfg_get(SavedConfig, session),
    Req = jsx:encode(#{<<"jsonrpc">> => <<"2.0">>, <<"id">> => 4, <<"method">> => <<"resources/read">>, <<"params">> => #{<<"uri">> => <<"resource://sys/datetime">>} }),
    HeadersRead = [{"x-api-key", "demo"}, {"mcp-session-id", Sess}],
    {ok, {{_P,200,_}, _H, Body}} = httpc:request(post, {Url, HeadersRead, "application/json", Req}, [], [{body_format, binary}]),
    Resp = jsx:decode(Body, [return_maps]),
    Contents = maps:get(<<"contents">>, maps:get(<<"result">>, Resp)),
    ?assert(is_list(Contents)),
     {save_config, [{session, Sess}]}.

cleanup_test(Config) ->
    ct:log("cleanup_test Config: ~p~n", [Config]),
    Url = cfg_get(Config, url),
    {resources_read_test, SavedConfig} = proplists:get_value(saved_config, Config, []),
    Sess = cfg_get(SavedConfig, session),
    {ok, {{_P,200,_}, _H, _B}} = httpc:request(delete, {Url, [{"x-api-key", "demo"}, {"mcp-session-id", Sess}]}, [], [{body_format, binary}]),
    catch emcp:stop(cfg_get(Config, listener)),
    {save_config, [{session, Sess}]}.

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

%% Ensure header values are charlists (httpc expects strings/lists)
header_string(V) when is_binary(V) -> binary_to_list(V);
header_string(V) -> V.

%% Ensure header name/values as binaries for cowboy/httpc compatibility
header_binary(V) when is_binary(V) -> V;
header_binary(V) when is_list(V) -> unicode:characters_to_binary(V).


find_header_case_insensitive(Headers, Name) when is_list(Headers) ->
    NameLower = string:to_lower(Name),
    LowKey = fun(K) -> case K of
                            K2 when is_binary(K2) -> string:to_lower(binary_to_list(K2));
                            K2 when is_list(K2) -> string:to_lower(K2)
                        end end,
    case lists:foldl(fun({K,V}, Acc) ->
                         case Acc of
                             {ok,_} -> Acc;
                             _ -> case LowKey(K) == NameLower of
                                      true -> {ok, header_binary(V)};
                                      false -> Acc
                                  end
                         end
                     end, false, Headers) of
        false -> {error, not_found};
        Res -> Res
    end.
