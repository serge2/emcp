-module(test_mcp).
-behaviour(emcp).

-export([schema/0, echo/3, resources_read/2, prompts_code_review/3, sleep/3]).

schema() ->
    #{
      name => <<"My App MCP">>,
      version => <<"0.1.0">>,
      title => <<"Test MCP implementation used in unit tests">>,
      instructions => <<"This MCP is used for unit testing the emcp framework. It provides a simple echo tool,"
                        " a resource for current date and time, and a prompt for code review.">>,
      tools => [
        #{ definition => #{ name => <<"echo">>,
                            description => <<"Simple echo tool">>,
                            inputSchema => #{ type => object,
                                              properties => #{ <<"message">> => #{ type => string } },
                                              required => [<<"message">>] } },
           function => fun echo/3
         },
        #{ definition => #{ name => <<"sleep">>,
                            description => <<"Sleep for given duration (ms)">>,
                            inputSchema => #{ type => object,
                                              properties => #{ <<"duration_ms">> => #{ type => integer, minimum => 0 } },
                                              required => [<<"duration_ms">>] } },
           function => fun sleep/3
         }
      ],
      resources => [
        #{ definition => #{ uri => <<"resource://sys/datetime">>,
                            name => <<"System date and time">>,
                            description => <<"Current local time">>,
                            mimeType => <<"text/plain">> },
           function => fun resources_read/2
         }
      ],
      prompts => [
        #{ definition => #{ name => <<"code_review">>,
                            title => <<"Request Code Review">>,
                            description => <<"Asks to review code">>,
                            arguments => [ #{ name => <<"code">>,
                                              description => <<"The code to review">>,
                                              required => true } ] },
           function => fun prompts_code_review/3
         }
      ]
    }.

%% Tool implementations

echo(_Name, #{<<"message">> := Msg}, _Extra) ->
    {ok, #{<<"text">> => Msg}}.

%% Sleep tool: pauses for the requested number of milliseconds and returns the duration
sleep(_Name, #{<<"duration_ms">> := Duration}, _Extra) when is_integer(Duration), Duration >= 0 ->
    timer:sleep(Duration),
    {ok, #{<<"slept_ms">> => Duration}}.

resources_read(URI, _Extra) ->
    [#{<<"uri">> => URI, <<"mimeType">> => <<"text/plain">>, <<"text">> => <<"now">>}].

prompts_code_review(_Name, #{<<"code">> := Code}, _Extra) ->
    {ok, #{<<"description">> => <<"Code review prompt">>,
           <<"messages">> => [ #{<<"role">> => <<"user">>, <<"content">> => #{<<"type">> => <<"text">>, <<"text">> => Code}} ] }}.
