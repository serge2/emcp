-module(emcp_session).
-behaviour(gen_server).

%% API
-export([start/2,
         stop/1,
         get_output_buf/1,
         initialize/2,
         initialized/1,
         tools_list/2,
         tools_call/3,
         resources_list/2,
         resources_read/3,
         cancelled/2
        ]).
%%-export([start_link/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

%% Types
-define(SERVER, ?MODULE).

%% API
start(SessionId, McpInfo) ->
    gen_server:start(?MODULE, [SessionId, McpInfo], []).

stop(Pid) ->
    gen_server:call(Pid, stop).

get_output_buf(Pid) ->
    gen_server:call(Pid, get_output_buf).

initialize(Pid, Params) ->
    gen_server:call(Pid, {initialize, Params}).

initialized(Pid) ->
    gen_server:call(Pid, initialized).

tools_list(Pid, RequestId) ->
    gen_server:call(Pid, {tools_list, RequestId}).

tools_call(Pid, RequestId, Params) ->
    gen_server:call(Pid, {tools_call, RequestId, Params}, infinity).

resources_list(Pid, RequestId) ->
    gen_server:call(Pid, {resources_list, RequestId}).

resources_read(Pid, RequestId, Params) ->
    gen_server:call(Pid, {resources_read, RequestId, Params}).

cancelled(Pid, Params) ->
    gen_server:call(Pid, {cancelled, Params}).

%% gen_server callbacks

init([SessionId, {McpModule, ExtraParams}]) ->
    %% Initial state: read raw schema from impl module, prepare tools and resources schemas once
    logger:info("Starting MCP session ~p with module ~p", [SessionId, McpModule]),
    RawSchema = McpModule:schema(),
    ToolsRaw = maps:get(tools, RawSchema, maps:get(<<"tools">>, RawSchema, [])),
    ResourcesRaw = maps:get(resources, RawSchema, maps:get(<<"resources">>, RawSchema, [])),
    ToolsSchema = convert_tools_for_client(ToolsRaw),
    ToolsArgsSchemas = generate_tools_args_schemas(ToolsSchema),
    ResourcesSchema = convert_tools_for_client(ResourcesRaw), %% same conversion logic
    ToolsFuns = extract_tools_funs(ToolsRaw),
    ResourcesFuns = extract_resources_funs(ResourcesRaw),
    {ok, #{ sid              => SessionId,
            output_buf       => [],
            output_req_id    => 1,
            mcp_module       => McpModule,
            extra_params     => ExtraParams,
            raw_schema       => RawSchema,
            tools_schema     => ToolsSchema,
            resources_schema => ResourcesSchema,
            tools_args_schemas => ToolsArgsSchemas,
            tools_funs       => ToolsFuns,
            resources_funs   => ResourcesFuns,
            active_requests  => #{},
            active_requests_rev => #{} }}.

handle_call(stop, _From, State) ->
    {stop, normal, ok, State};

handle_call(get_output_buf, _From, #{output_buf := OutputBuf}=State) ->
    {reply, lists:reverse(OutputBuf), State#{output_buf => []}};

handle_call({initialize, Params}, {Pid, _}=_From, State) ->
    try
        ClientCapabilites = maps:get(<<"capabilities">>, Params, #{}),

        RawSchema = maps:get(raw_schema, State, #{}),
        Name = get_schema_field(RawSchema, name, maps:get(<<"name">>, RawSchema, <<"MCP Server">>)),
        Version = get_schema_field(RawSchema, version, maps:get(<<"version">>, RawSchema, <<"undefined">>)),
        Description = get_schema_field(RawSchema, description, maps:get(<<"description">>, RawSchema, <<>>)),

        ServerInfo =
            #{ <<"name">> => Name,
               <<"version">> => Version,
               <<"description">> => Description
            },

        Resp =
            #{
                <<"protocolVersion">> => <<"2025-06-18">>,
                <<"capabilities">> => #{
                    <<"logging">> => #{},
                    <<"prompts">> => #{},
                    <<"resources">> => #{},
                    <<"tools">> => #{}
                },
                <<"serverInfo">> => ServerInfo,
                <<"instructions">> => <<"Optional instructions for the client">>
            },
        {reply, {ok, Resp}, State#{initialized => true,
                                   proto => <<"2025-06-18">>,
                                   client_capabilities => ClientCapabilites,
                                   client_pid => Pid}}
    catch
        Class:Reason ->
            {reply, {error, {Class, Reason}}, State}
    end;

handle_call(initialized, _From, State) ->
    logger:info("MCP session initialized"),
    State2 = check_roots(State),
    {reply, ok, State2#{initialized => true}};

handle_call({tools_list, RequestId}, From, #{tools_schema := Schema} = State) ->
    NewState = spawn_request_worker(tools_list, RequestId,
        fun() ->
            {ok, #{<<"tools">> => Schema}}
        end,
        From, State),
    {noreply, NewState};


handle_call({tools_call, RequestId, #{<<"name">> := NameBin, <<"arguments">> := Args}}, From,
            #{extra_params := ExtraParams, tools_args_schemas := ArgsSchemas} = State) ->
    NewState = spawn_request_worker(tools_call, RequestId,
        fun() ->
            case maps:find(NameBin, ArgsSchemas) of
                {ok, ArgsSchema} ->
                    case emcp_schema_validator:validate_params(ArgsSchema, Args) of
                        {ok, ValidatedArgs} ->
                            ToolsFuns = maps:get(tools_funs, State, #{}),
                            case maps:find(NameBin, ToolsFuns) of
                                {ok, Fun} ->
                                    case Fun(NameBin, ValidatedArgs, ExtraParams) of
                                        {ok, Ret} ->
                                            {ok, #{<<"content">> => Ret}};
                                        {structured_ok, Ret} ->
                                            {ok, #{<<"content">> => [#{<<"type">> => <<"text">>,
                                                                <<"text">> => jsx:encode(Ret)}
                                                                ],
                                            <<"structuredContent">> => Ret}};
                                        {error, Error} ->
                                                {ok, #{<<"content">> => [#{ <<"type">> => <<"text">>,
                                                                            <<"text">> => unicode:characters_to_binary([<<"Error: ">>, Error])
                                                                        }],
                                                    <<"isError">> => true}}
                                    end;
                                error ->
                                    {error, unsupported_tool}
                            end;
                        {error, ValidationError} ->
                            {error, {invalid_arguments, ValidationError}}
                    end;
                error ->
                    {error, unsupported_tool}
            end
        end,
        From, State),
    {noreply, NewState};

handle_call({resources_list, RequestId}, From, #{resources_schema := Schema} = State) ->
    NewState = spawn_request_worker(resources_list, RequestId,
        fun() ->
            {ok, #{<<"resources">> => Schema}}
        end,
        From, State),
    {noreply, NewState};
%    {reply, {ok, #{<<"resources">> => Schema}}, State};

handle_call({resources_read, RequestId, #{<<"uri">> := URI}}, From, #{extra_params := ExtraParams} = State) ->
    NewState = spawn_request_worker(resources_read, RequestId,
        fun() ->
            ResourcesFuns = maps:get(resources_funs, State, #{}),
            case find_resources_fun(ResourcesFuns, URI) of
                {ok, Fun} ->
                    {ok, #{<<"contents">> => Fun(URI, ExtraParams)}};
                error ->
                    {error, unsupported_resource}
            end
        end,
        From, State),
    {noreply, NewState};

handle_call({cancelled, #{<<"requestId">> := RequestId, <<"reason">> := Reason}}, _From, #{active_requests := AR} = State) ->
    case maps:find(RequestId, AR) of
        {ok, Pid} ->
            logger:info("Cancelling active request ~p (worker ~p), reason: ~p", [RequestId, Pid, Reason]),
            exit(Pid, kill),
            {reply, ok, State};
        error ->
            logger:info("No active request worker found for cancelled request ~p", [RequestId]),
            {reply, ok, State}
    end;

handle_call(Request, _From, State) ->
    logger:info("MCP session received unexpected call: ~p", [Request]),
    {reply, ok, State}.

handle_cast(Msg, State) ->
    logger:info("MCP session received unexpected cast: ~p", [Msg]),
    {noreply, State}.

handle_info({'DOWN', _MonitorRef, process, Pid, Info}, #{active_requests := AR, active_requests_rev := AR_Rev} = State) ->
    case maps:find(Pid, AR_Rev) of
        {ok, RequestId} ->
            logger:info("Request worker ~p for request ~p terminated: ~p", [Pid, RequestId, Info]),
            NewAR = maps:remove(RequestId, AR),
            NewAR_Rev = maps:remove(Pid, AR_Rev),
            {noreply, State#{active_requests => NewAR,
                             active_requests_rev => NewAR_Rev}};
        error ->
            {noreply, State}
    end;

handle_info(Info, State) ->
    logger:info("MCP session received unexpected info: ~p", [Info]),
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

-spec spawn_request_worker(atom(), integer(), fun(), any(), map()) -> map().
spawn_request_worker(Name, RequestId, Fun, From, #{active_requests := AR, active_requests_rev := AR_Rev} = State) ->
    {Pid, _MonRef} = proc_lib:spawn_opt(fun() ->
        Res = try
            Fun()
        catch
            Class:Reason ->
                logger:error("Request worker error for ~p (~p): ~p, ~p", [Name, RequestId, Class, Reason]),
                {error, {Class, Reason}}
        end,
        gen_server:reply(From, Res)
    end, [monitor]),
    State#{active_requests => AR#{RequestId => Pid},
           active_requests_rev => AR_Rev#{Pid => RequestId}}.   



%% find_resources_fun/2: try direct key lookup, otherwise compare canonical binary form of keys
-spec find_resources_fun(map(), binary()) -> {ok, term()} | error.
find_resources_fun(FunsMap, URI) when is_map(FunsMap), is_binary(URI) ->
    case maps:find(URI, FunsMap) of
        {ok, F} -> {ok, F};
        error -> error
     end;
find_resources_fun(_, _) -> error.



-spec check_roots(State::map()) -> State2::map().
check_roots(#{client_capabilities := ClientCapabilites} = State) ->
    case ClientCapabilites of
        #{<<"roots">> := #{}} ->
            put_request(State, #{<<"jsonrpc">> => <<"2.0">>,
                                 <<"method">> => <<"roots/list">>});
        _ ->
            State
    end.

-spec put_request(State::map(), Req::map()) -> State2::map().
put_request(State, Req) ->
    #{output_buf := OldBuf,
      output_req_id := ReqId} = State,
    NewBuf = [Req#{<<"id">> => ReqId} | OldBuf],
    State#{output_buf => NewBuf,
           output_req_id => ReqId + 1}.

%% Convert schema tools (stored with atom keys for fixed words) to client-friendly maps
-spec convert_tools_for_client(list()) -> list().
convert_tools_for_client(Tools) when is_list(Tools) ->
    [convert_map_for_client(T) || T <- Tools];
convert_tools_for_client(_) -> [].

-spec convert_map_for_client(map()) -> map().
convert_map_for_client(Map) when is_map(Map) ->
    lists:foldl(fun({K,V}, Acc) ->
                        case K of
                            function -> Acc; % omit implementation function
                            _ ->
                                NewK = key_to_bin(K),
                                NewV = convert_value_for_client(V),
                                maps:put(NewK, NewV, Acc)
                        end
                end, #{}, maps:to_list(Map));
convert_map_for_client(_) -> #{}.

%% key_to_bin: convert atom keys (fixed keywords) to binary, keep binary keys (user fields) as-is
key_to_bin(K) when is_atom(K) ->
    unicode:characters_to_binary(atom_to_list(K));
key_to_bin(K) when is_binary(K) ->
    K;
key_to_bin(K) when is_list(K) ->
    unicode:characters_to_binary(K);
key_to_bin(Other) ->
    unicode:characters_to_binary(io_lib:format("~p", [Other])).

%% convert_value_for_client: recursively convert schema values (atoms -> binaries, maps -> converted maps, lists -> converted lists)
convert_value_for_client(V) when is_map(V) ->
    % convert nested map but drop any 'function' keys
    lists:foldl(fun({K2,V2}, Acc) ->
                        case K2 of
                            function -> Acc;
                            _ ->
                                maps:put(key_to_bin(K2), convert_value_for_client(V2), Acc)
                        end
                end, #{}, maps:to_list(V));
convert_value_for_client(List) when is_list(List) ->
    [convert_value_for_client(E) || E <- List];
convert_value_for_client(A) when is_atom(A) ->
    unicode:characters_to_binary(atom_to_list(A));
convert_value_for_client(B) when is_binary(B) ->
    B;
convert_value_for_client(Other) ->
    Other.

%% extract_tools_funs: build map of tool name => function from raw tools schema
extract_tools_funs(ToolsRaw) when is_list(ToolsRaw) ->
    lists:foldl(fun(T, Acc) ->
        Name = maps:get(name, T),
        Fun = maps:get(function, T),
        maps:put(Name, Fun, Acc)
    end, #{}, ToolsRaw).

%% extract_resources_funs: build map of resource uri => function from raw resources schema
extract_resources_funs(ResourcesRaw) when is_list(ResourcesRaw) ->
    lists:foldl(fun(R, Acc) ->
        URI = maps:get(uri, R),
        Fun = maps:get(function, R),
        maps:put(URI, Fun, Acc)
    end, #{}, ResourcesRaw).

%% helper used above
get_schema_field(Schema, AtomKey, Default) ->
    case maps:find(AtomKey, Schema) of
        {ok, V} -> V;
        error ->
            BinKey = unicode:characters_to_binary(atom_to_list(AtomKey)),
            case maps:find(BinKey, Schema) of
                {ok, V2} -> V2;
                error -> Default
            end
    end.

generate_tools_args_schemas(ToolsSchema) when is_list(ToolsSchema) ->
    lists:foldl(fun(T, Acc) ->
        Name = maps:get(<<"name">>, T),
        ArgsSchema = maps:get(<<"inputSchema">>, T, #{}),
        maps:put(Name, ArgsSchema, Acc)
    end, #{}, ToolsSchema).