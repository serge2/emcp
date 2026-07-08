# emcp — Erlang MCP server framework

**Lightweight framework for building MCP (Model Context Protocol) services over HTTP(S).**

---

## Overview

emcp is a small Erlang framework for building MCP‑compatible services over HTTP(S). It provides session lifecycle management, support for tools, resources, prompts, client‑requested tool cancellation, and ping, as well as argument validation for tool calls based on incoming schemas.

## Features

- HTTP(S) transport for session initialization and MCP calls
- Declarative tool/resource/prompt schemas and argument validation for tool invocations based on incoming schemas
- Support for tools, resources, prompts, client‑requested tool cancellation, and ping
- Maximum tool execution timeout of 5 minutes
- Current limitations: resource lookup currently only matches names exactly; there is no validation for resource or prompt requests; dynamic capability changes are not supported; GET‑based subscription requests for messages are not supported
- Easy extension: add new tools, resources, and prompts by declaring schemas and implementing handler functions
- At the moment, the framework does not provide OAuth 2.1‑based user authorization; use API keys for access control instead

## Quick start (integration example)

emcp is intended to be used as a library/framework inside your application. The steps below show a minimal integration example:

1. Create a new Erlang application and add the dependency:

```sh
rebar3 new app my_app
cd my_app
```

Add emcp to your `rebar.config` dependencies (use the appropriate git/hex reference for your setup):

```erlang
{deps, [
  {emcp, "*", {git, "https://github.com/serge2/emcp.git", {branch, "master"}}}
]}.
```

Add emcp to the src file:
```erlang
    ...
    {applications, [
        kernel,
        stdlib,
        emcp
    ]},
    ...
```
 

2. Implement an MCP module inside your application. Minimal example:

```erlang
-module(my_app_mcp).
-export([schema/0]).

schema() ->
  #{
    name => <<"My App MCP">>,
    version => <<"0.1.0">>,
    title => <<"My app MCP implementation">>,
    tools => [
      #{ 
         definition => #{
            name => <<"echo">>,
            description => <<"Simple echo tool">>,
            inputSchema => #{ type => object, properties => #{ <<"message">> => #{ type => string } }, required => [<<"message">>] }
         },
         function => fun echo/3
       }
    ],
    resources => [
      #{ 
         definition => #{
            uri => <<"resource://sys/datetime">>,
            name => <<"System date and time">>,
            description => <<"Current local time, UTC time and time-zone">>,
            mimeType => <<"text/plain">>
         },
         function => fun resources_read/2
       }
    ],
    prompts => [
      #{
         definition => #{
            name => <<"code_review">>,
            title => <<"Request Code Review">>,
            description => <<"Asks the LLM to analyze code quality and suggest improvements">>,
            arguments => [
              #{
                name => <<"code">>,
                description => <<"The code to review">>,
                required => true
              }
            ]
         },
         function => fun prompts_code_review/3
       }
    ]
  }.

echo(_Name, #{<<"message">> := Msg}, _Extra) ->
  {ok, #{<<"text">> => Msg}}.

resources_read(URI, _Extra) ->
  Text = unicode:characters_to_binary(os:cmd("LC_ALL=C timedatectl | head -n4 | sed s/^[[:space:]]*//")),
  [#{<<"uri">> => URI, <<"mimeType">> => <<"text/plain">>, <<"text">> => Text}].

prompts_code_review(_Name, #{<<"code">> := Code}, _Extra) ->
  Prompt = unicode:characters_to_binary([<<"Please review this Python code:\n">>, Code]),
  {ok, #{<<"description">> => <<"Code review prompt">>,
         <<"messages">> => [
          #{
            <<"role">> => <<"user">>,
            <<"content">> => #{<<"type">> => <<"text">>, <<"text">> => Prompt}
          }
         ]
        }}.


```


3. Add configuration values to *your* application's config (not the dependency). For example, in your `sys.config` / config provider:

```erlang
[
 {my_app, [{api_keys, ["secret-key-1"]}]},
 {emcp, [{tls, [{keyfile, "/etc/ssl/key.pem"}, {certfile, "/etc/ssl/cert.pem"}]}]}
].
```

4. There are two ways to start an MCP server: as a dedicated http-listener or as a part of a custom cowboy listener

Start the MCP as a dedicated listener:

```erlang
-module(my_app_app).

-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    AllowedApiKeys = application:get_env(my_app, api_keys, []),
    emcp:start(my_app_mcp_listener, my_app_mcp, {0,0,0,0}, 8080, "/mcp", _UseTLS = false, AllowedApiKeys, _Extra = #{}),
    my_app_sup:start_link().

stop(_State) ->
    emcp:stop(my_app_mcp_listener),
    ok.
```

Start the MCP as a part of a custom listener:

```erlang
-module(my_app_app).

-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    AllowedApiKeys = application:get_env(my_app, api_keys, []),

    Dispatch = cowboy_router:compile([
        {'_', [
          emcp:cowboy_route("/mcp", test_mcp, AllowedApiKeys, #{}), % The route for the MCP
          {<<"/[...]">>, main_handler, #{}}     % A route for another requests
        ]}
    ]),

    {ok, _} = cowboy:start_clear(
        http_listener,
        [{port, 8080}, {ip, {0,0,0,0}}],
        #{env => #{dispatch => Dispatch}}
    ),
    my_app_sup:start_link().

stop(_State) ->
    cowboy:stop_listener(http_listener),
    ok.
```



5. Build and run your application:

```sh
rebar3 compile
rebar3 shell
# in the Erlang shell
application:ensure_all_started(my_app).
```


## Usage example (HTTP / JSON‑RPC)

Initialize a session (include API key if the server is configured to require one — `x-api-key` or `Authorization: Bearer <token>`):

```sh
curl -i -X POST http://localhost:8080/mcp \
  -H 'Content-Type: application/json' \
  -H 'x-api-key: secret-key-1' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}'
```

The response will include an `Mcp-Session-Id` header — include it in subsequent calls:

### Get a list of implemented tools:
```sh
curl -i -X POST http://localhost:8080/mcp \
  -H 'Content-Type: application/json' \
  -H 'x-api-key: secret-key-1' \
  -H 'Mcp-Session-Id: <session-id>' \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'
```

### Call the echo tool:
```sh
curl -i -X POST http://localhost:8080/mcp \
  -H 'Content-Type: application/json' \
  -H 'x-api-key: secret-key-1' \
  -H 'Mcp-Session-Id: <session-id>' \
  -d '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"echo","arguments":{"message": "Hello, world!"}}}'
```

### Read resource example (system datetime):
```sh
curl -i -X POST http://localhost:8080/mcp \
  -H 'Content-Type: application/json' \
  -H 'x-api-key: secret-key-1' \
  -H 'Mcp-Session-Id: <session-id>' \
  -d '{"jsonrpc":"2.0","id":4,"method":"resources/read","params":{"uri":"resource://sys/datetime"}}'
```
### Get a list of prompts:
```sh
curl -i -X POST http://localhost:8080/mcp \
  -H 'Content-Type: application/json' \
  -H 'x-api-key: secret-key-1' \
  -H 'Mcp-Session-Id: <session-id>' \
  -d '{"jsonrpc":"2.0","id":5,"method":"prompts/list","params":{}}'
```
### Get a prompt:
```sh
curl -i -X POST http://localhost:8080/mcp \
  -H 'Content-Type: application/json' \
  -H 'x-api-key: secret-key-1' \
  -H 'Mcp-Session-Id: <session-id>' \
  -d '{"jsonrpc":"2.0","id":6,"method":"prompts/get","params":{"name": "code_review", "arguments": {"code": "def hello():\n    print('world')"}}}'
```

## Copyright and License

Copyright (c) 2025-2026 Sergii Polkovnikov <serge.polkovnikov@gmail.com>

This project is licensed under the MIT License. See [LICENSE](LICENSE) for the full text.



