-module(test_mcp).

-export([schema/0, echo/3, resources_read/2, prompts_code_review/3]).

schema() ->
    #{
      name => <<"My App MCP">>,
      version => <<"0.1.0">>,
      description => <<"Test MCP implementation used in unit tests">>,
      tools => [
        #{ definition => #{ name => <<"echo">>,
                           description => <<"Simple echo tool">>,
                           inputSchema => #{ type => object,
                                             properties => #{ <<"message">> => #{ type => string } },
                                             required => [<<"message">>] }
                         },
           function => fun echo/3
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
        #{ definition => #{ name => <<"code_review">>, title => <<"Request Code Review">>, description => <<"Asks to review code">>, arguments => [ #{ name => <<"code">>, description => <<"The code to review">>, required => true } ] },
           function => fun prompts_code_review/3
         }
      ]
    }.

%% Tool implementations

echo(_Name, #{<<"message">> := Msg}, _Extra) ->
    {ok, #{<<"text">> => Msg}}.

resources_read(URI, _Extra) ->
    [#{<<"uri">> => URI, <<"mimeType">> => <<"text/plain">>, <<"text">> => <<"now">>}].

prompts_code_review(_Name, #{<<"code">> := Code}, _Extra) ->
    {ok, #{<<"description">> => <<"Code review prompt">>,
           <<"messages">> => [ #{<<"role">> => <<"user">>, <<"content">> => #{<<"type">> => <<"text">>, <<"text">> => Code}} ] }}.
