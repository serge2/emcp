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
         prompts_list/2,
         prompts_get/3,
         cancelled/2,
         ping/2
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

prompts_list(Pid, RequestId) ->
    gen_server:call(Pid, {prompts_list, RequestId}).

prompts_get(Pid, RequestId, Params) ->
    gen_server:call(Pid, {prompts_get, RequestId, Params}).

cancelled(Pid, Params) ->
    gen_server:call(Pid, {cancelled, Params}).

ping(Pid, RequestId) ->
    gen_server:call(Pid, {ping, RequestId}).


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

handle_call({initialize, Params}, {Pid, _}=_From, State) ->
    try
        ClientCapabilites = maps:get(<<"capabilities">>, Params, #{}),

        RawSchema = maps:get(raw_schema, State, #{}),
        Name = maps:get(name, RawSchema, <<"MCP Server">>),
        Version = maps:get(version, RawSchema, <<"undefined">>),
        Description = maps:get(description, RawSchema, <<>>),

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
        Class:Reason:_Stacktrace ->
            {reply, {error, {Class, Reason}}, State}
    end;

handle_call(initialized, _From, State) ->
    logger:info("MCP session initialized"),
    State2 = check_roots(State),
    {reply, ok, State2#{initialized => true}};

handle_call({tools_list, RequestId}, From, #{tools_defs := Definitions} = State) ->
    NewState = spawn_request_worker(tools_list, RequestId,
        fun() ->
            {ok, #{<<"tools">> => Definitions}}
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

handle_call({resources_list, RequestId}, From, #{resources_defs := Definitions} = State) ->
    NewState = spawn_request_worker(resources_list, RequestId,
        fun() ->
            {ok, #{<<"resources">> => Definitions}}
        end,
        From, State),
    {noreply, NewState};

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

handle_call({prompts_list, RequestId}, From, #{prompts_defs := Definitions} = State) ->
    NewState = spawn_request_worker(prompts_list, RequestId,
        fun() ->
            {ok, #{<<"prompts">> => Definitions}}
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
                                            {ok, Result};
                                        {error, _Error} ->
                                                {error, internal}
                                    end;
                                error ->
                                    {error, unsupported_prompt}
                            end;
                        {error, _ValidationError} ->
                            {error, invalid_arguments}
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
            logger:info("Cancelling active request ~p (worker ~p), reason: ~p", [RequestId, Pid, Reason]),
            exit(Pid, kill),
            {reply, ok, State};
        error ->
            logger:info("No active request worker found for cancelled request ~p", [RequestId]),
            {reply, ok, State}
    end;

handle_call({ping, _RequestId}, _From, State) ->
    {reply, {ok, pong}, State};

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
            Class:Reason:Stacktrace ->
                logger:error("Request worker error for ~p (~p): ~p, ~p~n~tp", [Name, RequestId, Class, Reason, Stacktrace]),
                {error, internal}
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