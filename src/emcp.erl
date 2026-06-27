-module(emcp).
-export([start/8, stop/1, cowboy_route/4]).
-ignore_xref([
    {emcp, start, 8},
    {emcp, stop, 1},
    {emcp, cowboy_route, 4}
]).

-callback schema() ->
    #{
      name => binary(),
      version => binary(),
      title := binary(),
      instructions := binary(),
      tools := [],
      resources := [],
      prompts := []
     }.

-spec start(Name, Module, IP, Port, Path, UseTLS, AllowedApiKeys, ExtraParams) -> {ok, pid()} | {error, term()} when
      Name :: atom(),
      Module :: module(),
      IP :: tuple(),
      Port :: integer(),
      Path :: binary() | string(),
      UseTLS :: boolean(),
      AllowedApiKeys :: [binary()],
      ExtraParams :: map().
start(Name, Module, IP, Port, Path, UseTLS, AllowedApiKeys, ExtraParams) when
  is_atom(Name),
  is_atom(Module),
  is_tuple(IP),
  is_integer(Port),
  is_binary(Path) orelse is_list(Path),
  is_boolean(UseTLS),
  is_list(AllowedApiKeys),
  is_map(ExtraParams) ->
    Dispatch = cowboy_router:compile([
        {'_', [cowboy_route(Path, Module, AllowedApiKeys, ExtraParams)]}
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

-spec stop(Name) -> ok when Name :: atom().
stop(Name) ->
    logger:info("Stopping MCP listener ~p...", [Name]),
    cowboy:stop_listener(Name).

-spec cowboy_route(Path, Module, AllowedApiKeys, ExtraParams) -> {PathMatch::any(), Handler::module(), Opts::any()} when
      Path :: binary() | string(),
      Module :: module(),
      AllowedApiKeys :: [binary() | list()],
      ExtraParams :: map().
cowboy_route(Path, Module, AllowedApiKeys, ExtraParams) when
      is_binary(Path) orelse is_list(Path),
      is_atom(Module),
      is_list(AllowedApiKeys),
      is_map(ExtraParams) ->
    if AllowedApiKeys == [] ->
           logger:info("No API keys configured; all requests will be failed.");
       true ->
           logger:info("API key authentication enabled; ~w keys configured.", [length(AllowedApiKeys)])
    end,
    NormalizedKeys = normalize_api_keys(AllowedApiKeys),
    {
        list_to_binary([Path, <<"/[...]">>]),
        emcp_http_handler,
        #{api_keys => NormalizedKeys, module => Module, extra_params => ExtraParams}
    }.

-spec normalize_api_keys(Keys :: [binary() | list()] ) -> [binary()].
normalize_api_keys(Keys) ->
    [to_binary_normalized(X) || X <- Keys].

-spec to_binary_normalized(Item :: binary() | list()) -> binary().
to_binary_normalized(Item) when is_binary(Item) -> Item;
to_binary_normalized(Item) when is_list(Item) -> unicode:characters_to_binary(Item).
