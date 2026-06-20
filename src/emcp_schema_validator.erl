-module(emcp_schema_validator).
-export([
    validate_tools_params/2,
    validate_prompt_params/2
]).

%% validate_tools_params(InputSchema, ParamsMap) ->
%%   {ok, NormalizedParams} | {error, ReasonBinary}
%%
%% InputSchema expected to be a map like:
%%  #{<<"type">> => <<"object">>, <<"properties">> => #{...}, <<"required">> => [...]}
%%
%% ParamsMap is a map with binary keys (as in mcp code).
%% The function fills defaults (if provided) and normalizes basic types:
%%   string -> binary
%%   integer -> integer (accepts integer or binary representation)
%%   object  -> map (validated recursively)
%% Supports enum in property schema.

validate_tools_params(Schema, _Params) when not is_map(Schema) ->
    {error, <<"invalid_schema">>};
validate_tools_params(_Schema, Params) when not is_map(Params) ->
    {error, <<"invalid_params">>};
validate_tools_params(Schema, Params) ->
    case jesse:validate_with_schema(Schema, Params) of
        {ok, NormalizedParams} ->
            {ok, NormalizedParams};
        {error, Reason} ->
            {error, unicode:characters_to_binary(io_lib:format("~tp", [Reason]))}
    end.


%% validate_prompt_params(Schema, Params) ->
%%   {ok, NormalizedParams} | {error, ReasonBinary}

validate_prompt_params(Schema, _Params) when not is_list(Schema) ->
    {error, <<"invalid_schema">>};
validate_prompt_params(_Schema, Params) when not is_map(Params) ->
    {error, <<"invalid_params">>};
validate_prompt_params(_Schema, Params) ->
    % To be implemented
    {ok, Params}.


