-module(emcp).
-export([start/8, stop/1]).


-callback schema() ->
    #{
      name => binary(),
      version => binary(),
      description => binary(),
      tools => [],
      resources => []
     }.


start(Name, Module, IP, Port, Path, UseTLS, AllowedApiKeys, ExtraParams) ->
    AllowedKeys = normalize_api_keys(AllowedApiKeys),
    if AllowedKeys == [] ->
           logger:info("No API keys configured; all requests will be accepted.");
       true ->
           logger:info("API key authentication enabled; ~w keys configured.", [length(AllowedKeys)])
    end,
    Dispatch = cowboy_router:compile([
        {'_', [{list_to_binary([Path, <<"/[...]">>]), emcp_http_handler,
             #{api_keys => AllowedKeys, module => Module, extra_params => ExtraParams} }]}
    ]),

    if not UseTLS ->
            logger:info("Starting HTTP (clear) listener on ~p:~p", [IP, Port]),
            {ok, _} = cowboy:start_clear(Name,
                                         [{port, Port}
                                          ,{ip, IP }
                                         ],
                                         #{env => #{dispatch => Dispatch}}
                                        );
        true ->
            TLS = application:get_env(emcp, tls, []),
            Keyfile = proplists:get_value(keyfile, TLS, undefined),
            Certfile = proplists:get_value(certfile, TLS, undefined),
            logger:info("Starting HTTPS (TLS) listener on ~p:~p, keyfile=~p certfile=~p", [IP, Port, Keyfile, Certfile]),
            {ok, _} = cowboy:start_tls(Name,
                                       [{port, Port}
                                        ,{ip, IP }
                                        ,{keyfile, Keyfile}
                                        ,{certfile, Certfile}
                                       ],
                                       #{env => #{dispatch => Dispatch},
                                         secure_renegotiate => true
                                       })
    end.

stop(Name) ->
    logger:info("Stopping MCP listener ~p...", [Name]),
    cowboy:stop_listener(Name).

normalize_api_keys(Keys) ->
    case Keys of
        K when is_list(K) ->
            [to_binary_normalized(X) || X <- K];
        K when is_binary(K) ->
            [K];
        _ ->
            [] % unexpected config -> treat as no keys
    end.

to_binary_normalized(Item) when is_binary(Item) -> Item;
to_binary_normalized(Item) when is_list(Item) -> unicode:characters_to_binary(Item).
