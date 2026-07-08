-module(emcp_http_handler).
-behaviour(cowboy_handler).

-export([init/2]).

-define(RESOURCE_NOT_FOUND, -32002).
-define(INVALID_REQUEST, -32600).
-define(METHOD_NOT_FOUND, -32601).
-define(INVALID_PARAMS, -32602).
-define(INTERNAL_ERROR, -32603).
-define(PARSE_ERROR, -32700).

-spec init(cowboy_req:req(), Opts::any()) -> {ok, cowboy_req:req(), State::any()}.
init(Req0, Opts) ->
    Method = cowboy_req:method(Req0),
    case Method of
        <<"POST">> -> handle_post(Req0, Opts);
        <<"DELETE">> -> handle_delete(Req0, Opts);
        _ ->
            logger:error("Unsupported method: ~ts", [Method]),
            Req = cowboy_req:reply(
                405,
                #{
                    <<"content-type">> => <<"plain/text">>,
                    <<"allow">> => <<"POST, DELETE">>
                },
                <<"Method Not Allowed">>,
                Req0
            ),
            {ok, Req, undefined}
    end.

handle_post(Req0, #{api_keys := ApiKeys, module := McpModule, extra_params := ExtraParams} = _Opts) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Headers = cowboy_req:headers(Req1),
    FinReq =
        case validate_api_key(Req1, ApiKeys) of
            ok ->
                try jsx:decode(Body, [return_maps]) of
                    Json ->
                        logger:info("HTTP Request:~nHeaders:~n~p~nBody:~n~ts~n", [Headers, Body]),
                        SessionId = get_session_id(Req1),
                        try handle_post_jsonrpc(Json, SessionId, {McpModule, ExtraParams}) of
                            {ResponseStatus, OutHeaders, RespBin, OutputBuf} ->
                                do_reply(Req1, ResponseStatus, OutHeaders, RespBin, OutputBuf)
                        catch
                            Class:Reason:Stack ->
                                logger:error("handle_post_jsonrpc exception:~n~p:~p ~tp", [Class, Reason, Stack]),
                                Error = #{<<"jsonrpc">> => <<"2.0">>,
                                        <<"error">> => #{<<"code">> => ?INTERNAL_ERROR,
                                                        <<"message">> => <<"Internal error">>}},
                                cowboy_req:reply(500, #{<<"content-type">> => <<"application/json">>}, jsx:encode(Error), Req1)
                        end
                catch
                    _Class:_Reason:_Stack ->
                        logger:error("Failed to decode request body. Headers:~n~tp~nBody:~n~ts~n", [Headers, Body]),
                        Error = #{<<"jsonrpc">> => <<"2.0">>,
                                <<"error">> => #{<<"code">> => ?PARSE_ERROR,
                                                <<"message">> => <<"Parse error">>}},
                        cowboy_req:reply(400, #{<<"content-type">> => <<"application/json">>}, jsx:encode(Error), Req1)
                end;
            {error, Reason} ->
                logger:error("Invalid API-Key:~ts.~nHTTP Request:~nHeaders:~n~p~nBody:~n~ts~n", [Reason, Headers, Body]),
                cowboy_req:reply(401, #{<<"content-type">> => <<"plain/text">>}, Reason, Req1)
        end,
    {ok, FinReq, undefined}.

handle_delete(Req, #{api_keys := ApiKeys} = _Opts) ->
    %% Delete session
    Headers = cowboy_req:headers(Req),
    FinReq =
        case validate_api_key(Req, ApiKeys) of
            ok ->
                SessionId = get_session_id(Req),
                case find_session(SessionId) of
                    {ok, Pid} ->
                        ok = emcp_session:stop(Pid),
                        true = ets:delete(mcp_sessions, SessionId),
                        cowboy_req:reply(200, #{<<"content-type">> => <<"application/json">>,
                                                    <<"connection">> => <<"close">>},
                                                <<"{\"ok\":true}">>, Req);
                    {error, undefined} ->
                        Error = #{<<"jsonrpc">> => <<"2.0">>,
                                <<"error">> => #{<<"code">> => ?INVALID_REQUEST,
                                                <<"message">> => <<"Invalid session">>}},
                        cowboy_req:reply(400, #{<<"content-type">> => <<"application/json">>}, jsx:encode(Error), Req);
                    {error, not_found} ->
                        Error = #{<<"jsonrpc">> => <<"2.0">>,
                                <<"error">> => #{<<"code">> => ?INVALID_REQUEST,
                                                <<"message">> => <<"Session not found">>}},
                        cowboy_req:reply(404, #{<<"content-type">> => <<"application/json">>}, jsx:encode(Error), Req)
                end;
            {error, Reason} ->
                logger:error("Invalid API-Key:~ts.~nHTTP Request:~nHeaders:~n~p~n", [Reason, Headers]),
                cowboy_req:reply(401, #{<<"content-type">> => <<"plain/text">>}, Reason, Req)
        end,
    {ok, FinReq, undefined}.



do_reply(Req, ResponseStatus, OutHeaders, RespBin, OutputBuf) ->
    ParsedAccept = cowboy_req:parse_header(<<"accept">>, Req, []),
    
    %% Check whether any of them is text/event-stream
    IsSseSupported = lists:any(
        fun({{Type, SubType, _}, _Quality, _Ext}) -> 
            Type =:= <<"text">> andalso SubType =:= <<"event-stream">>
        end, 
        ParsedAccept),

    case IsSseSupported of    
        false ->
            %% The client does not support SSE -> return regular JSON
            cowboy_req:reply(ResponseStatus,
                             OutHeaders#{<<"content-type">> => <<"application/json">>},
                             RespBin, Req);
        true ->
            %% The client supports SSE -> stream chunks
            StreamReq = cowboy_req:stream_reply(ResponseStatus,
                OutHeaders#{
                    <<"content-type">> => <<"text/event-stream">>,
                    <<"transfer-encoding">> => <<"chunked">>,
                    <<"cache-control">> => <<"no-cache">>,
                    <<"x-accel-buffering">> => <<"no">>,
                    <<"connection">>    => <<"keep-alive">>
                    },
                Req),
            try
                stream_chunks(StreamReq, OutputBuf ++ [RespBin]),
                StreamReq
            catch Class:Reason:Stack ->
                logger:error("SSE error ~p:~p ~p", [Class, Reason, Stack]),
                %% send an empty FIN chunk to close the connection
                cowboy_req:stream_events(#{data => <<>>}, fin, StreamReq)
            end
    end.


%% Sending SSE events
stream_chunks(StreamReq, []) ->
    logger:info("SSE: empty response, closing stream"),
    cowboy_req:stream_events(#{ data => <<>>}, fin, StreamReq);
stream_chunks(StreamReq, [Last]) ->
    logger:info("SSE: sending the final chunk of size ~p bytes with FIN~n~ts~n", [byte_size(Last), Last]),
    cowboy_req:stream_events(#{ data => Last}, fin, StreamReq);
stream_chunks(StreamReq, [H | T]) ->
    logger:info("SSE: sending chunk of size ~p bytes (remaining ~p)", [byte_size(H), length(T)]),
    cowboy_req:stream_events(#{ data => H}, nofin, StreamReq),
    stream_chunks(StreamReq, T).





%% @doc Dispatches a JSON-RPC request or notification to the appropriate handler.
%% Expects a map representing a JSON-RPC 2.0 object and SessionId.
-spec handle_post_jsonrpc(map(), binary() | undefined, {module(), term()}) ->
    {HTTPStatus::integer(), OutHeaders::map(), Response::binary(), OutputBuf::list()} |
    no_return().
handle_post_jsonrpc(#{<<"jsonrpc">> := <<"2.0">>, <<"method">> := _, <<"id">> := RequestId} = Request, SessionId, McpInfo) ->
    case handle_post_call(Request, SessionId, McpInfo) of
        {{reply, ReplyRaw}, OutputBuf} ->
            Reply = #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => RequestId, <<"result">> => ReplyRaw},
            logger:info("HTTP Reply(raw):~n~tp~n", [Reply]),
            {200, #{}, jsx:encode(Reply), OutputBuf};
        {{new_session, ReplyRaw, SessionId2}, OutputBuf} ->
            Reply = #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => RequestId, <<"result">> => ReplyRaw},
            logger:info("HTTP Reply(raw):~n~tp~n", [Reply]),
            OutHeaders = #{<<"Mcp-Session-Id">> => SessionId2},
            {200, OutHeaders, jsx:encode(Reply), OutputBuf};
        {error, ResponseStatus, Reply} ->
            {ResponseStatus, #{}, jsx:encode(Reply), []}
    end;

handle_post_jsonrpc(#{<<"jsonrpc">> := <<"2.0">>, <<"method">> := _} = Notification, SessionId, _McpInfo) ->
    case handle_post_notification(Notification, SessionId) of
        {noreply, OutputBuf} ->
            {202, #{}, <<>>, OutputBuf}
   end;

handle_post_jsonrpc(_Json, _SessionId, _McpInfo) ->
    error(client_error).



handle_post_call(#{<<"method">> := <<"initialize">>} = Request, _SessionId, McpInfo) ->
    logger:info("Initializing new MCP session..."),
    SessionId = gen_uuid_v7(),
    {ok, Pid} = emcp_sup:start_session(SessionId, McpInfo), 
    ok = register_session(SessionId, Pid),
    logger:info("Initialized new MCP session ~p with pid ~p", [SessionId, Pid]),
    case do_call_in_session(Request, SessionId) of 
        {{reply, Resp}, OutputBuf} ->
            {{new_session, Resp, SessionId}, OutputBuf};
        {error, Status, Resp} ->
            {error, Status, Resp}
    end;

handle_post_call(Request, SessionId, _) ->
    do_call_in_session(Request, SessionId).


handle_post_notification(Notification, SessionId) ->
    do_notification_in_session(Notification, SessionId).


register_session(SessionId, Pid) ->
    true = ets:insert(mcp_sessions, {SessionId, Pid}),
    ok.

do_call_in_session(#{<<"method">> := Method} = Request, SessionId) ->
    RequestId = maps:get(<<"id">>, Request),
    Params = maps:get(<<"params">>, Request, #{}),
    case find_session(SessionId) of
        {ok, Pid} ->
            case emcp_session:in_request(Pid, Method, RequestId, Params) of
                {reply, Resp} ->
                    OutputBuf = emcp_session:get_output_buf(Pid),
                    {{reply, Resp}, OutputBuf};
                {error, internal} ->
                    {error, 500,
                     #{<<"jsonrpc">> => <<"2.0">>,
                       <<"id">> => RequestId,
                       <<"error">> => #{<<"code">> => ?INTERNAL_ERROR,
                                        <<"message">> => <<"Internal error">>}}};
                {error, unsupported_resource} ->
                    {error, 400,
                     #{<<"jsonrpc">> => <<"2.0">>,
                       <<"id">> => RequestId,
                       <<"error">> => #{<<"code">> => ?RESOURCE_NOT_FOUND,
                                        <<"message">> => <<"Resource not found">>}}};
                {error, unsupported_prompt} ->
                    {error, 400,
                     #{<<"jsonrpc">> => <<"2.0">>,
                       <<"id">> => RequestId,
                       <<"error">> => #{<<"code">> => ?INVALID_PARAMS,
                                        <<"message">> => <<"Invalid prompt name">>}}};
                {error, unsupported_tool} ->
                    {error, 400,
                     #{<<"jsonrpc">> => <<"2.0">>,
                       <<"id">> => RequestId,
                       <<"error">> => #{<<"code">> => ?INVALID_PARAMS,
                                        <<"message">> => <<"Unknown tool">>}}};
                {error, Resp} ->
                    {error, 400,
                     #{<<"jsonrpc">> => <<"2.0">>,
                       <<"id">> => RequestId,
                       <<"error">> => #{<<"code">> => ?INVALID_REQUEST,
                                        <<"message">> => <<"Invalid request">>,
                                        <<"data">> => unicode:characters_to_binary(io_lib:format("~p", [Resp]))}}}
            end;
        {error, undefined} ->
            {error, 400,
             #{<<"jsonrpc">> => <<"2.0">>,
               <<"id">> => RequestId,
               <<"error">> => #{<<"code">> => ?INVALID_REQUEST,
                                <<"message">> => <<"Invalid session">>}}};
        {error, not_found} ->
            {error, 404,
             #{<<"jsonrpc">> => <<"2.0">>,
               <<"id">> => RequestId,
               <<"error">> => #{<<"code">> => ?INVALID_REQUEST,
                                <<"message">> => <<"Session not found">>}}}
    end.


do_notification_in_session(#{<<"method">> := Method} = Notification, SessionId) ->
    Params = maps:get(<<"params">>, Notification, #{}),
    case find_session(SessionId) of
        {ok, Pid} ->
            case emcp_session:in_notification(Pid, Method, Params) of
                noreply ->
                    OutputBuf = emcp_session:get_output_buf(Pid),
                    {noreply, OutputBuf}
             end;
        {error, undefined} ->
            {error, 400,
             #{<<"jsonrpc">> => <<"2.0">>,
               <<"error">> => #{<<"code">> => ?INVALID_REQUEST,
                                <<"message">> => <<"Invalid session">>}}};
        {error, not_found} ->
            {error, 404,
             #{<<"jsonrpc">> => <<"2.0">>,
               <<"error">> => #{<<"code">> => ?INVALID_REQUEST,
                                <<"message">> => <<"Session not found">>}}}
    end.


-spec find_session(binary() | undefined) -> {ok, pid()} | {error, Error} when
    Error :: not_found | undefined.
find_session(undefined) ->
    {error, undefined};
find_session(SessionId) when is_binary(SessionId) ->
    case ets:lookup(mcp_sessions, SessionId) of
        [{SessionId, Pid}] ->
            {ok, Pid};
        [] ->
            {error, not_found}
    end.

-spec gen_uuid_v7() -> UUID::binary().
gen_uuid_v7() ->
    %% 1. Get current Unix time in milliseconds
    SystemMillis = erlang:system_time(millisecond),

    %% 2. Generate 10 random bytes (80 bits of entropy)
    RandomBytes = crypto:strong_rand_bytes(10),
    <<RandA:12, RandB:62, _:6>> = RandomBytes,

    %% 3. Construct the raw 128-bit UUIDv7 binary according to RFC 9562
    %% ver = 7 (4 bits: 0111), var = 2 (2 bits: 10)
    RawUUID = <<SystemMillis:48, 7:4, RandA:12, 2:2, RandB:62>>,

    %% 4. Convert the binary to a canonical hex string (8-4-4-4-12)
    <<C1:8/binary, C2:4/binary, C3:4/binary, C4:4/binary, C5:12/binary>> = binary:encode_hex(RawUUID, lowercase),
    
    %% Assemble the final hyphenated binary string
    <<C1/binary, "-", C2/binary, "-", C3/binary, "-", C4/binary, "-", C5/binary>>.


-spec get_session_id(cowboy_req:req()) -> binary() | undefined.
get_session_id(Req) ->
    cowboy_req:header(<<"mcp-session-id">>, Req, undefined).


%% API key support (configured in app config as mcp, api_keys = [<<"key1">>, "key2", ...])
-spec validate_api_key(cowboy_req:req(), [binary()]) -> ok | {error, Reason::binary()}.
validate_api_key(Req, ApiKeys) when  is_list(ApiKeys) ->
    case get_api_key_from_headers(Req) of
        undefined ->
            {error, <<"missing_api_key">>};
        Key ->
            case lists:member(Key, ApiKeys) of
                true -> ok;
                false ->
                    {error, <<"invalid_api_key">>}
            end
    end.

-spec get_api_key_from_headers(cowboy_req:req()) -> binary() | undefined.
get_api_key_from_headers(Req) ->
    %% First, check the prioritized x-api-key (it returns a binary or undefined)
    case cowboy_req:header(<<"x-api-key">>, Req) of
        Key when is_binary(Key) ->
            Key;
        undefined ->
            %% If it is missing, parse the standard Authorization
            case cowboy_req:parse_header(<<"authorization">>, Req) of
                {bearer, Token} ->
                    Token;
                _ ->
                    undefined %% If there is Basic auth, Digest, or no header at all
            end
    end.


