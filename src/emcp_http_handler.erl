-module(emcp_http_handler).
-behaviour(cowboy_handler).

-include_lib("kernel/include/file.hrl").

-export([init/2]).


init(Req0, State) ->
    Method = cowboy_req:method(Req0),
    case Method of
        <<"POST">> -> handle_post(Req0, State);
        <<"GET">> -> handle_get(Req0, State);
        <<"DELETE">> -> handle_delete(Req0, State);
        _ ->
            logger:error("Unsupported method: ~ts", [Method]),
            Req = cowboy_req:reply(405, #{<<"content-type">> => <<"application/json">>},
                                   <<"{\"error\":\"method_not_allowed\"}">>, Req0),
            {ok, Req, undefined}
    end.

handle_get(Req0, #{api_keys := ApiKeys} = _State) ->
    Headers = cowboy_req:headers(Req0),
    case validate_api_key(Headers, ApiKeys) of
        ok ->
            %% Simple health check
            Body = <<"{\"ok\":true,\"service\":\"mcp_fs\",\"version\":\"0.1.0\"}">>,
            Req = cowboy_req:reply(200, #{<<"content-type">> => <<"application/json">>}, Body, Req0),
            {ok, Req, undefined};
        {error, Reason} ->
            logger:error("Invalid API-Key:~ts.~nHTTP Request:~nHeaders:~n~p~n", [Reason, Headers]),
            Req = cowboy_req:reply(401, #{<<"content-type">> => <<"plain/text">>}, Reason, Req0),
            {ok, Req, undefined}
    end.

handle_post(Req0, #{api_keys := ApiKeys, module := McpModule, extra_params := ExtraParams} = _State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Headers = cowboy_req:headers(Req1),
    case validate_api_key(Headers, ApiKeys) of
        ok ->
            case jsx:is_json(Body) of
                true ->
                    Json = jsx:decode(Body, [return_maps]),
                    logger:info("HTTP Request:~nHeaders:~n~p~nBody:~n~ts~n", [Headers, Body]),
                    try handle_post_jsonrpc(Json, Headers, {McpModule, ExtraParams}) of
                        {ResponseStatus, OutHeaders, RespBin, OutputBuf} ->
                            do_reply(Req1, Headers, ResponseStatus, OutHeaders, RespBin, OutputBuf)
                    catch
                        Class:Reason:Stack ->
                            logger:error("handle_post_jsonrpc exception:~n~p:~p ~tp", [Class, Reason, Stack]),
                            Req4 = cowboy_req:reply(500, #{<<"content-type">> => <<"application/json">>},
                                                    <<"{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32603,\"message\":\"Internal error\"}}">>, Req1),
                            {ok, Req4, undefined}
                    end;

                false ->
                    logger:error("Faild to decode request body. Headers:~n~tp~nBosy:~n~ts~n", [Headers, Body]),
                    Req2 = cowboy_req:reply(400, #{<<"content-type">> => <<"application/json">>},
                                            <<"{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32700,\"message\":\"Parse error\"}}">>, Req1),
                    {ok, Req2, undefined}
            end;
        {error, Reason} ->
            logger:error("Invalid API-Key:~ts.~nHTTP Request:~nHeaders:~n~p~nBody:~n~ts~n", [Reason, Headers, Body]),
            Req = cowboy_req:reply(401, #{<<"content-type">> => <<"plain/text">>}, Reason, Req1),
            {ok, Req, undefined}
    end.

handle_delete(Req, #{api_keys := ApiKeys} = _State) ->
    %% Delete session
    Headers = cowboy_req:headers(Req),
    case validate_api_key(Headers, ApiKeys) of
        ok ->
            SessionId = get_session_id(Headers),
            case find_session(SessionId) of
                {ok, Pid} ->
                    ok = emcp_session:stop(Pid),
                    true = ets:delete(mcp_sessions, SessionId),
                    Req2 = cowboy_req:reply(200, #{<<"content-type">> => <<"application/json">>,
                                                   <<"connection">> => <<"close">>},
                                            <<"{\"ok\":true}">>, Req),
                    {ok, Req2, undefined};
                {error, Reason} ->
                    Error = #{<<"jsonrpc">> => <<"2.0">>,
                              <<"error">> => #{<<"code">> => -32001, <<"message">> => <<"Invalid session">>,
                                               <<"data">> => unicode:characters_to_binary(io_lib:format("~p", [Reason]))}},
                    Req2 = cowboy_req:reply(400, #{<<"content-type">> => <<"application/json">>}, jsx:encode(Error), Req),
                    {ok, Req2, undefined}
            end;
        {error, Reason} ->
            logger:error("Invalid API-Key:~ts.~nHTTP Request:~nHeaders:~n~p~n", [Reason, Headers]),
            Req = cowboy_req:reply(401, #{<<"content-type">> => <<"plain/text">>}, Reason, Req),
            {ok, Req, undefined}
    end.



do_reply(Req, InHeaders, ResponseStatus, OutHeaders, RespBin, OutputBuf) ->
    AcceptHeader = maps:get(<<"accept">>, InHeaders, <<>>),
    SupportedAccepts = parse_accept_header(AcceptHeader),
    case lists:member(<<"text/event-stream">>, SupportedAccepts) of
        false ->
            %% Клиент не поддерживает SSE -> возвращаем обычный JSON
            ReqJson = cowboy_req:reply(ResponseStatus,
                                       OutHeaders#{<<"content-type">> => <<"application/json">>},
                                       RespBin, Req),
            {ok, ReqJson, undefined};
        true ->
            %% Клиент поддерживает SSE -> стримим чанки
            StreamReq = cowboy_req:stream_reply(ResponseStatus,
                OutHeaders#{
                    <<"content-type">> => <<"text/event-stream">>,
                    <<"transfer-encoding">> => <<"chunked">>,
                    <<"cache-control">> => <<"no-cache">>,
                    <<"connection">>    => <<"keep-alive">>
                    },
                Req),
            try
                stream_chunks(StreamReq, OutputBuf ++ [RespBin])
            catch Class:Reason:Stack ->
                logger:error("SSE error ~p:~p ~p", [Class, Reason, Stack]),
                %% отправляем пустой FIN‑чанк, чтобы закрыть соединение
                cowboy_req:stream_events(#{data => <<>>}, fin, StreamReq)
            end,
            {ok, StreamReq, undefined}
    end.


%% Отправка событий SSE
stream_chunks(StreamReq, []) ->
  logger:info("SSE: пустой ответ, закрываем поток"),
  cowboy_req:stream_events(#{ data => <<>>}, fin, StreamReq);
stream_chunks(StreamReq, [Last]) ->
  logger:info("SSE: отправляем последний чанк размером ~p байт с FIN~n~ts~n", [byte_size(Last), Last]),
  cowboy_req:stream_events(#{ data => Last}, fin, StreamReq);
stream_chunks(StreamReq, [H | T]) ->
  logger:info("SSE: отправляем чанк размером ~p байт (осталось ~p)", [byte_size(H), length(T)]),
  cowboy_req:stream_events(#{ data => H}, nofin, StreamReq),
  stream_chunks(StreamReq, T).





%% @doc Dispatches a JSON-RPC request or notification to the appropriate handler.
%% Expects a map representing a JSON-RPC 2.0 object and HTTP headers.
-spec handle_post_jsonrpc(map(), map(), atom()) ->
    {HTTPStatus::integer(), OutHeaders::map(), Response::binary(), OutputBuf::list()} |
    no_return().
handle_post_jsonrpc(#{<<"jsonrpc">> := <<"2.0">>, <<"method">> := _, <<"id">> := RequestId} = Request, Headers, McpInfo) ->
    case handle_post_call(Request, Headers, McpInfo) of
        {noreply, OutputBuf} ->
            {202, #{}, <<>>, OutputBuf};
        {{reply, ReplyRaw}, OutputBuf} ->
            Reply = #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => RequestId, <<"result">> => ReplyRaw},
            logger:info("HTTP Reply(raw):~n~tp~n", [Reply]),
            {200, #{}, jsx:encode(Reply), OutputBuf};
        {{reply, ReplyRaw, SessionId}, OutputBuf} ->
            Reply = #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => RequestId, <<"result">> => ReplyRaw},
            logger:info("HTTP Reply(raw):~n~tp~n", [Reply]),
            %% Это инициализация - добавляем заголовок с SessionId
            OutHeaders = #{<<"Mcp-Session-Id">> => SessionId},
            {200, OutHeaders, jsx:encode(Reply), OutputBuf};
        {error, ResponseStatus, Reply} ->
            {ResponseStatus, #{}, jsx:encode(Reply), []}
    end;

handle_post_jsonrpc(#{<<"jsonrpc">> := <<"2.0">>, <<"method">> := _} = Notification, Headers, _McpInfo) ->
    case handle_post_notification(Notification, Headers) of
        {noreply, OutputBuf} ->
            {202, #{}, <<>>, OutputBuf};
        {{reply, ReplyRaw}, OutputBuf} ->
            Reply = #{<<"jsonrpc">> => <<"2.0">>, <<"result">> => ReplyRaw},
            logger:info("HTTP Reply(raw):~n~tp~n", [Reply]),
            {200, #{}, jsx:encode(Reply), OutputBuf};
        {error, ResponseStatus, Reply} ->
            {ResponseStatus, #{}, jsx:encode(Reply), []}
    end;

handle_post_jsonrpc(_Json, _Headers, _McpInfo) ->
    error(client_error).



handle_post_call(#{<<"method">> := <<"initialize">>, <<"params">> := Params} = Request, _Headers, McpInfo) ->
    logger:info("Initializing new MCP session..."),
    SessionId = gen_uuid_v7(),
    {ok, Pid} = emcp_session:start(SessionId, McpInfo),
    ok = register_session(SessionId, Pid),
    logger:info("Initialized new MCP session ~p with pid ~p", [SessionId, Pid]),
    case emcp_session:initialize(Pid, Params) of
        {reply, Result} ->
            OutputBuf = emcp_session:get_output_buf(Pid),
            {{reply,
              #{<<"jsonrpc">> => <<"2.0">>,
                <<"id">> => maps:get(<<"id">>, Request),
                <<"result">> => Result},
              SessionId}, OutputBuf};
        {error, _Reason} ->
            {error, 500,
             #{<<"jsonrpc">> => <<"2.0">>,
               <<"id">> => maps:get(<<"id">>, Request),
               <<"error">> => #{<<"code">> => -32000, <<"message">> => <<"Server error">>}}}
    end;

handle_post_call(#{<<"method">> := <<"tools/list">>} = Request, Headers, _) ->
    do_call_in_session(Request, Headers, fun emcp_session:tools_list/3); %% (Pid, RequestId, Params)

handle_post_call(#{<<"method">> := <<"tools/call">>} = Request, Headers, _) ->
    do_call_in_session(Request, Headers, fun emcp_session:tools_call/3); %% (Pid, RequestId, Params)

handle_post_call(#{<<"method">> := <<"resources/list">>} = Request, Headers, _) ->
    do_call_in_session(Request, Headers, fun emcp_session:resources_list/3); %% (Pid, RequestId, Params)

handle_post_call(#{<<"method">> := <<"resources/read">>} = Request, Headers, _) ->
    do_call_in_session(Request, Headers, fun emcp_session:resources_read/3); %% (Pid, RequestId, Params)

 handle_post_call(#{<<"method">> := <<"prompts/list">>} = Request, Headers, _) ->
    do_call_in_session(Request, Headers, fun emcp_session:prompts_list/3); %% (Pid, RequestId, Params)

handle_post_call(#{<<"method">> := <<"prompts/get">>} = Request, Headers, _) ->
    do_call_in_session(Request, Headers, fun emcp_session:prompts_get/3); %% (Pid, RequestId, Params)

handle_post_call(#{<<"method">> := <<"ping">>} = Request, Headers, _) ->
    do_call_in_session(Request, Headers, fun emcp_session:ping/3); %% (Pid, RequestId, Params)

handle_post_call(Request, _Headers, _) ->
    {error, 400,
        #{<<"jsonrpc">> => <<"2.0">>,
          <<"id">> => maps:get(<<"id">>, Request),
          <<"error">> => #{<<"code">> => -32001, <<"message">> => <<"Unsupported method">>}}}.


handle_post_notification(#{<<"method">> := <<"notifications/initialized">>} = Notification, Headers) ->
    do_notification_in_session(Notification, Headers, fun emcp_session:initialized/2); %% (Pid, Params)

handle_post_notification(#{<<"method">> := <<"notifications/cancelled">>} = Notification, Headers) ->
    do_notification_in_session(Notification, Headers, fun emcp_session:cancelled/2); %% (Pid, Params)

handle_post_notification(Notification, _Headers) ->
    logger:error("Unknown notification:~n~p~n", [Notification]),
    noreply.

register_session(SessionId, Pid) ->
    true = ets:insert(mcp_sessions, {SessionId, Pid}),
    ok.

do_call_in_session(Request, Headers, CallFun) ->
    RequestId = maps:get(<<"id">>, Request),
    Params = maps:get(<<"params">>, Request, #{}),
    do_in_session(Headers, fun(Pid) ->
        CallFun(Pid, RequestId, Params)
    end).

do_notification_in_session(Notification, Headers, NotifFun) ->
    Params = maps:get(<<"params">>, Notification, #{}),
    do_in_session(Headers, fun(Pid) ->
        NotifFun(Pid, Params)
    end).

do_in_session(Headers, Fun) ->
    SessionId = get_session_id(Headers),
    case find_session(SessionId) of
        {ok, Pid} ->
            case Fun(Pid) of
                noreply ->
                    OutputBuf = emcp_session:get_output_buf(Pid),
                    {noreply, OutputBuf};
                {reply, Resp} ->
                    OutputBuf = emcp_session:get_output_buf(Pid),
                    {{reply, Resp}, OutputBuf};
                {reply, Resp, SessionId2} ->
                    OutputBuf = emcp_session:get_output_buf(Pid),
                    {{reply, Resp, SessionId2}, OutputBuf};
                {error, Status, Resp} ->
                    {error, Status, Resp}
            end;
        {error, Reason} ->
            {error, 400,
             #{<<"jsonrpc">> => <<"2.0">>,
               <<"error">> => #{<<"code">> => -32001, <<"message">> => <<"Invalid session">>,
                               <<"data">> => unicode:characters_to_binary(io_lib:format("~p", [Reason]))}}}
    end.

find_session(SessionId) when is_binary(SessionId) ->
    case ets:lookup(mcp_sessions, SessionId) of
        [{SessionId, Pid}] ->
            {ok, Pid};
        [] ->
            {error, not_found}
    end;
find_session(_) ->
    {error, invalid_session_id}.

gen_uuid_v7() ->
    %% Получаем время в миллисекундах с Unix epoch
    {Mega, Sec, Micro} = os:timestamp(),
    UnixMillis = (Mega * 1000000 + Sec) * 1000 + (Micro div 1000),

    %% UUIDv7: 48 бит времени, 12 бит версии, 62 бит случайных
    <<Time48:48>> = <<UnixMillis:48>>,
    Random = crypto:strong_rand_bytes(10), %% 80 бит

    <<RandA:12/integer, RandB:62/integer, _:6>> = Random,

    %% Формируем UUID поля
    Version = 7, %% 4 бита
    Hi = (RandA band 16#0FFF) bor (Version bsl 12), %% 16 бит: 4 версии + 12 рандом
    Variant = (RandB bsr 62) bor 2#10, %% 2 бита variant RFC4122

    %% Собираем UUID
    list_to_binary(io_lib:format("~12.16.0B-~4.16.0B-~4.16.0B-~4.16.0B-~12.16.0B",
        [Time48,
         Hi band 16#FFFF,
         (Hi bsr 16) band 16#FFFF,
         (Variant bsl 14) bor ((RandB bsr 48) band 16#3FFF),
         RandB band 16#FFFFFFFFFFFF])).



get_session_id(Headers) ->
    maps:get(<<"mcp-session-id">>, Headers, undefined).

-spec parse_accept_header(Header::binary()) -> [MediaType::binary()].
parse_accept_header(AcceptHeader) when is_binary(AcceptHeader) ->
    %% Преобразуем AcceptHeader в строку и разбиваем по запятым
    Types0 = binary:split(AcceptHeader, <<",">>, [global]),
    %% Парсим каждый тип, извлекая media type и q-параметр
    Types1 = [parse_accept_type(string:trim(Type, both, " ") ) || Type <- Types0],
    %% Сортируем по q (приоритету), по убыванию
    Sorted = lists:sort(fun({_, Q1}, {_, Q2}) -> Q1 > Q2 end, Types1),
    %% Возвращаем только типы
    [Type || {Type, _Q} <- Sorted].

parse_accept_type(TypeBin) ->
    %% Разделяем параметры
    [MediaType | Params] = binary:split(TypeBin, <<";">>, [global]),
    Q = case [P || P <- Params, binary:match(P, <<"q=">>) =/= nomatch] of
            [QParam | _] ->
                case binary:split(QParam, <<"=">>) of
                    [_, QVal] ->
                        case string:to_float(QVal) of
                            {F, <<>>} -> F;
                            {error, no_float} ->
                                case string:to_integer(QVal) of
                                    {I, <<>>} -> float(I);
                                    {error, no_integer} -> 1.0
                                end;
                            _ -> 1.0
                        end;
                    _ -> 1.0
                end;
            _ -> 1.0
        end,
    {string:trim(MediaType, both, [<<" ">>]), Q}.

%% new helpers: API key support (configured in app config as mcp, api_keys = [<<"key1">>, "key2", ...])
validate_api_key(Headers, ApiKeys) when is_map(Headers), is_list(ApiKeys) ->
    case get_api_key_from_headers(Headers) of
        undefined ->
            {error, <<"missing_api_key">>};
        Key ->
            case lists:member(Key, ApiKeys) of
                true -> ok;
                false ->
                    {error, <<"invalid_api_key">>}
            end
    end.

%% @doc Extracts the API key from HTTP headers, supporting both "x-api-key" and "authorization: Bearer ..." formats.
-spec get_api_key_from_headers(map()) -> binary() | undefined.
get_api_key_from_headers(Headers) when is_map(Headers) ->
    %% Prefer X-API-Key header
    case maps:get(<<"x-api-key">>, Headers, undefined) of
        Key when is_binary(Key) -> Key;
        _ ->
            case maps:get(<<"authorization">>, Headers, undefined) of
                Auth when is_binary(Auth) ->
                    case binary:split(Auth, <<" ">>, [global]) of
                        [Scheme, Token] ->
                            LowerScheme = string:to_lower(binary_to_list(Scheme)),
                            case LowerScheme of
                                "bearer" -> Token;
                                _ -> undefined
                            end;
                        _ -> undefined
                    end;
                _ -> undefined
            end
    end.



