-module(emcp_session).
-behaviour(gen_server).

%% API
-export([start/2,
         stop/1,
         get_output_buf/1,
         in_request/4,
         in_notification/3
        ]).
%%-export([start_link/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).


%% API
start(SessionId, McpInfo) ->
    gen_server:start(?MODULE, [SessionId, McpInfo], []).

stop(Pid) ->
    gen_server:call(Pid, stop).

get_output_buf(Pid) ->
    gen_server:call(Pid, get_output_buf).

-spec in_request(pid(), Name::binary(), RequestId::integer(), Params::map()) -> {reply, map()} | {error, Error} when
        Error :: unsupported_tool | {invalid_arguments, binary()} | unsupported_resource | unsupported_prompt | internal.
in_request(Pid, <<"initialize">>, _RequestId, Params) ->
    gen_server:call(Pid, {initialize, Params});
in_request(Pid, <<"tools/list">>, RequestId, _Params) ->
    gen_server:call(Pid, {tools_list, RequestId});
in_request(Pid, <<"tools/call">>, RequestId, Params) ->
    gen_server:call(Pid, {tools_call, RequestId, Params}, 300_000); %% longer timeout for potentially long-running tool calls
in_request(Pid, <<"resources/list">>, RequestId, _Params) ->
    gen_server:call(Pid, {resources_list, RequestId});
in_request(Pid, <<"resources/read">>, RequestId, Params) ->
    gen_server:call(Pid, {resources_read, RequestId, Params});
in_request(Pid, <<"prompts/list">>, RequestId, _Params) ->
    gen_server:call(Pid, {prompts_list, RequestId});
in_request(Pid, <<"prompts/get">>, RequestId, Params) ->
    gen_server:call(Pid, {prompts_get, RequestId, Params});
in_request(Pid, <<"ping">>, RequestId, _Params) ->
    gen_server:call(Pid, {ping, RequestId}).

in_notification(Pid, <<"notifications/cancelled">>, Params) ->
    gen_server:call(Pid, {cancelled, Params});
in_notification(Pid, <<"notifications/initialized">>, Params) ->
    gen_server:call(Pid, {initialized, Params}).


%% gen_server callbacks

init([SessionId, {McpModule, ExtraParams}]) ->
    %% Initial state: read raw schema from impl module, prepare tools and resources schemas once
    logger:info("Starting MCP session ~p with module ~p", [SessionId, McpModule]),
    MCPSchema = McpModule:schema(),
    Tools = maps:get(tools, MCPSchema, []),
    Resources = maps:get(resources, MCPSchema, []),
    Prompts = maps:get(prompts, MCPSchema, []),
    ToolsDefinitions = get_definitions(Tools),
    ToolsInputSchemas = get_input_schemas(ToolsDefinitions),
    ToolsFuns = get_function(Tools),
    ResourcesDefinitions = get_definitions(Resources), %% same conversion logic
    ResourcesFuns = get_resources_function(Resources),
    PromptsDefinitions = get_definitions(Prompts), %% same conversion logic
    PromptsArgsSchemas = get_argument_schemas(PromptsDefinitions),
    PromptsFuns = get_function(Prompts),
    {ok, #{ sid              => SessionId,
            output_buf       => [],
            output_req_id    => 1,
            mcp_module       => McpModule,
            extra_params     => ExtraParams,
            mcp_schema       => MCPSchema,     % Not used directly, but may be useful for debugging
            tools_defs       => ToolsDefinitions,
            resources_defs   => ResourcesDefinitions,
            prompts_defs     => PromptsDefinitions,
            tools_args_schemas => ToolsInputSchemas,
            tools_funs       => ToolsFuns,
            resources_funs   => ResourcesFuns,
            prompts_args_schemas => PromptsArgsSchemas,
            prompts_funs     => PromptsFuns,
            active_requests  => #{},
            active_requests_rev => #{}
         }}.

handle_call(stop, _From, State) ->
    {stop, normal, ok, State};

handle_call(get_output_buf, _From, #{output_buf := OutputBuf}=State) ->
    {reply, lists:reverse(OutputBuf), State#{output_buf => []}};

handle_call({initialize, Params}, _From, State) ->
    try
        InitializeResult = prepare_initialize_result(State),
        ClientCapabilites = maps:get(<<"capabilities">>, Params, #{}),
        {reply, {reply, InitializeResult},
         State#{initialized => true,
                proto => <<"2025-06-18">>,
                client_capabilities => ClientCapabilites}}
    catch
        Class:Reason:Stacktrace ->
            logger:error("Initialization error. Params: ~tp~n~p, ~p~n~tp", [Params, Class, Reason, Stacktrace]),
            {reply, {error, internal}, State}
    end;

handle_call(initialized, _From, State) ->
    logger:info("MCP session initialized"),
    State2 = check_roots(State),
    {reply, noreply, State2#{initialized => true}};

handle_call({tools_list, RequestId}, From, #{tools_defs := Definitions} = State) ->
    NewState = spawn_request_worker(tools_list, RequestId,
        fun() ->
            {reply, #{<<"tools">> => Definitions}}
        end,
        From, State),
    {noreply, NewState};


handle_call({tools_call, RequestId, #{<<"name">> := NameBin, <<"arguments">> := Args}}, From,
            #{extra_params := ExtraParams, tools_args_schemas := ArgsSchemas} = State) ->
    NewState = spawn_request_worker(tools_call, RequestId,
        fun() ->
            case maps:find(NameBin, ArgsSchemas) of
                {ok, ArgsSchema} ->
                    case emcp_schema_validator:validate_tools_params(ArgsSchema, Args) of
                        {ok, ValidatedArgs} ->
                            ToolsFuns = maps:get(tools_funs, State, #{}),
                            case maps:find(NameBin, ToolsFuns) of
                                {ok, Fun} ->
                                    case Fun(NameBin, ValidatedArgs, ExtraParams) of
                                        {ok, Ret} ->
                                            {reply, #{<<"content">> => Ret}};
                                        {structured_ok, Ret} ->
                                            {reply, #{<<"content">> => [#{<<"type">> => <<"text">>,
                                                                <<"text">> => jsx:encode(Ret)}
                                                                ],
                                                      <<"structuredContent">> => Ret}};
                                        {error, Error} ->
                                            {reply, #{<<"content">> => [#{ <<"type">> => <<"text">>,
                                                                            <<"text">> => unicode:characters_to_binary([<<"Error: ">>, Error])
                                                                        }],
                                                     <<"isError">> => true}}
                                    end;
                                error ->
                                    {error, unsupported_tool}
                            end;
                        {error, ValidationError} ->
                            logger:error("Validation error: ~tp", [ValidationError]),
                            {error, {invalid_arguments, ValidationError}}
                    end;
                error ->
                    {error, unsupported_tool}
            end
        end,
        From, State),
    {noreply, NewState};

handle_call({resources_list, RequestId}, From, #{resources_defs := Definitions} = State) ->
    NewState = spawn_request_worker(resources_list, RequestId,
        fun() ->
            {reply, #{<<"resources">> => Definitions}}
        end,
        From, State),
    {noreply, NewState};

handle_call({resources_read, RequestId, #{<<"uri">> := URI}}, From, #{extra_params := ExtraParams} = State) ->
    NewState = spawn_request_worker(resources_read, RequestId,
        fun() ->
            ResourcesFuns = maps:get(resources_funs, State, #{}),
            case find_resources_fun(ResourcesFuns, URI) of
                {ok, Fun} ->
                    {reply, #{<<"contents">> => Fun(URI, ExtraParams)}};
                error ->
                    {error, unsupported_resource}
            end
        end,
        From, State),
    {noreply, NewState};

handle_call({prompts_list, RequestId}, From, #{prompts_defs := Definitions} = State) ->
    NewState = spawn_request_worker(prompts_list, RequestId,
        fun() ->
            {reply, #{<<"prompts">> => Definitions}}
        end,
        From, State),
    {noreply, NewState};

handle_call({prompts_get, RequestId, #{<<"name">> := NameBin, <<"arguments">> := Args}}, From,
             #{extra_params := ExtraParams, prompts_args_schemas := ArgsSchemas} = State) ->
    NewState = spawn_request_worker(prompts_get, RequestId,
        fun() ->
            case maps:find(NameBin, ArgsSchemas) of
                {ok, ArgsSchema} ->
                    case emcp_schema_validator:validate_prompt_params(ArgsSchema, Args) of
                        {ok, ValidatedArgs} ->
                            PromptsFuns = maps:get(prompts_funs, State, #{}),
                            case maps:find(NameBin, PromptsFuns) of
                                {ok, Fun} ->
                                    case Fun(NameBin, ValidatedArgs, ExtraParams) of
                                        {ok, Result} ->
                                            {reply, Result};
                                        {error, _Error} ->
                                            {error, internal}
                                    end;
                                error ->
                                    {error, unsupported_prompt}
                            end;
                        {error, ValidationError} ->
                            {error, {invalid_arguments, ValidationError}}
                    end;
                error ->
                    {error, unsupported_prompt}
            end
        end,
        From, State),
    {noreply, NewState};

handle_call({cancelled, #{<<"requestId">> := RequestId, <<"reason">> := Reason}}, _From, #{active_requests := AR} = State) ->
    case maps:find(RequestId, AR) of
        {ok, Pid} ->
            logger:warning("Cancelling active request ~p (worker ~p), reason: ~p", [RequestId, Pid, Reason]),
            exit(Pid, kill),
            {reply, noreply, State};
        error ->
            logger:warning("No active request worker found for cancelled request ~p", [RequestId]),
            {reply, noreply, State}
    end;

handle_call({ping, _RequestId}, _From, State) ->
    {reply, {reply, #{}}, State};

handle_call(Request, _From, State) ->
    logger:info("MCP session received unexpected call: ~p", [Request]),
    {reply, noreply, State}.

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
            Class:Reason:Stacktrace ->
                logger:error("Request worker error for ~p (~p): ~p, ~p~n~tp", [Name, RequestId, Class, Reason, Stacktrace]),
                {error, internal}
        end,
        gen_server:reply(From, Res)
    end, [monitor]),
    State#{active_requests => AR#{RequestId => Pid},
           active_requests_rev => AR_Rev#{Pid => RequestId}}.   




prepare_initialize_result(#{mcp_schema := MCPSchema}) ->
    ServerInfo = prepare_server_info(MCPSchema),
    OptionalList = [{'_meta', <<"_meta">>},
                    {instructions, <<"instructions">>}],
    MandatoryItems= #{
        <<"protocolVersion">> => <<"2025-06-18">>,
        <<"serverInfo">> => ServerInfo,
        <<"capabilities">> => #{
            % <<"completions"> => #{},
            % <<"experimental">> => #{},
            % <<"logging">> => #{},
            <<"prompts">> => #{},
            <<"resources">> => #{},
            <<"tools">> => #{}
        }
    },
    lists:foldl(fun({Key, BinKey}, Acc) ->
                    case maps:find(Key, MCPSchema) of
                        {ok, Val} ->
                            maps:put(BinKey, Val, Acc);
                        error ->
                            Acc
                    end
                end, MandatoryItems, OptionalList).



prepare_server_info(MCPSchema) ->
    MandatoryList = [{name, <<"name">>},
                     {version, <<"version">>}],
    OptionalList  = [{title, <<"title">>}],

    I1 = lists:foldl(fun({Key, BinKey}, Acc) ->
                        case maps:find(Key, MCPSchema) of
                            {ok, Val} ->
                                maps:put(BinKey, Val, Acc);
                            error ->
                                error({no_mandatory_key, Key})
                        end
                    end, #{}, MandatoryList),
    I2 = lists:foldl(fun({Key, BinKey}, Acc) ->
                        case maps:find(Key, MCPSchema) of
                            {ok, Val} ->
                                maps:put(BinKey, Val, Acc);
                            error ->
                                Acc
                        end
                    end, I1, OptionalList),
    maps:merge(I1, I2).

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


get_definitions(List) when is_list(List) ->
    [jsx:decode(jsx:encode(Def), []) || #{definition := Def} <- List].

get_function(List) when is_list(List) ->
    lists:foldl(fun(#{definition := Def} = R, Acc) ->
        Name = maps:get(name, Def),
        Fun = maps:get(function, R),
        maps:put(Name, Fun, Acc)
    end, #{}, List).

get_resources_function(List) when is_list(List) ->
    lists:foldl(fun(#{definition := Def} = R, Acc) ->
        Name = maps:get(uri, Def),
        Fun = maps:get(function, R),
        maps:put(Name, Fun, Acc)
    end, #{}, List).

get_input_schemas(ToolsSchema) when is_list(ToolsSchema) ->
    lists:foldl(fun(T, Acc) ->
        Name = maps:get(<<"name">>, T),
        ArgsSchema = maps:get(<<"inputSchema">>, T, #{}),
        maps:put(Name, ArgsSchema, Acc)
    end, #{}, ToolsSchema).

get_argument_schemas(PromptsSchema) when is_list(PromptsSchema) ->
    lists:foldl(fun(T, Acc) ->
        Name = maps:get(<<"name">>, T),
        ArgsSchema = maps:get(<<"arguments">>, T, []),
        maps:put(Name, ArgsSchema, Acc)
    end, #{}, PromptsSchema).