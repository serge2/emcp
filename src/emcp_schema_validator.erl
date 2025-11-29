-module(emcp_schema_validator).
-export([validate_params/2]).

%% validate_params(InputSchema, ParamsMap) ->
%%   {ok, NormalizedParamsMap} | {error, ReasonBinary}
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

validate_params(#{<<"type">> := <<"object">>} = Schema, Params) when is_map(Params) ->
    Props = maps:get(<<"properties">>, Schema, #{}),
    Required = maps:get(<<"required">>, Schema, []),
    validate_properties(Props, Required, Params);
validate_params(_, _) ->
    {error, <<"unsupported_schema">>}.

%% iterate properties, validate each present or apply default
validate_properties(Props, Required, Params) ->
    PropList = maps:to_list(Props),
    do_validate_props(PropList, Required, Params, #{}).

do_validate_props([], _Required, _Params, Acc) ->
    {ok, Acc};
do_validate_props([{Name, PropSchema} | T], Required, Params, Acc) ->
    case maps:find(Name, Params) of
        {ok, Value} ->
            case validate_value(PropSchema, Value) of
                {ok, Norm} ->
                    do_validate_props(T, Required, Params, maps:put(Name, Norm, Acc));
                {error, Reason} ->
                    {error, Reason}
            end;
        error ->
            case maps:find(<<"default">>, PropSchema) of
                {ok, Def} ->
                    case validate_value(PropSchema, Def) of
                        {ok, NormDef} ->
                            do_validate_props(T, Required, Params, maps:put(Name, NormDef, Acc));
                        {error, Reason} ->
                            {error, Reason}
                    end;
                error ->
                    case lists:member(Name, Required) of
                        true -> {error, <<"missing_required_parameter">>};
                        false -> do_validate_props(T, Required, Params, Acc)
                    end
            end
    end.

%% validate_value/2 checks type, enum, and recurses for objects
validate_value(PropSchema, Value) when is_map(PropSchema) ->
    Type = maps:get(<<"type">>, PropSchema, <<"string">>),
    case Type of
        <<"string">> ->
            case normalize_string(Value) of
                {ok, Bin} ->
                    check_enum(PropSchema, Bin);
                {error, R} -> {error, R}
            end;
        <<"integer">> ->
            case normalize_integer(Value) of
                {ok, Int} ->
                    check_enum(PropSchema, Int);
                {error, R} -> {error, R}
            end;
        <<"boolean">> ->
            case normalize_boolean(Value) of
                {ok, B} ->
                    check_enum(PropSchema, B);
                {error, R} -> {error, R}
            end;
        <<"object">> ->
            case is_map(Value) of
                true ->
                    NestedSchema = case maps:get(<<"properties">>, PropSchema, undefined) of
                                       undefined -> #{<<"type">> => <<"object">>, <<"properties">> => #{}, <<"required">> => []};
                                       _ -> PropSchema
                                   end,
                    case validate_params(NestedSchema, Value) of
                        {ok, NormMap} -> check_enum(PropSchema, NormMap);
                        Err -> Err
                    end;
                false -> {error, <<"invalid_type_expected_object">>}
            end;
        <<"array">> ->
            %% basic array handling: validate items schema if provided
            ItemsSchema = maps:get(<<"items">>, PropSchema, undefined),
            case is_list(Value) of
                true ->
                    case validate_array_items(ItemsSchema, Value, []) of
                        {ok, NormList} -> check_enum(PropSchema, NormList);
                        Err -> Err
                    end;
                false -> {error, <<"invalid_type_expected_array">>}
            end;
        _Other ->
            {error, <<"unsupported_type">>}
    end.

check_enum(PropSchema, Value) ->
    case maps:find(<<"enum">>, PropSchema) of
        {ok, EnumList} when is_list(EnumList) ->
            %% normalize enum entries to binaries/integers/booleans for comparison
            case enum_member(Value, EnumList) of
                true -> {ok, Value};
                false -> {error, <<"value_not_in_enum">>}
            end;
        _ -> {ok, Value}
    end.

%% validate each array item against items schema
validate_array_items(undefined, List, AccRev) ->
    {ok, lists:reverse(AccRev)};
validate_array_items(ItemsSchema, [H|T], AccRev) ->
    case validate_value(ItemsSchema, H) of
        {ok, Norm} -> validate_array_items(ItemsSchema, T, [Norm|AccRev]);
        Err -> Err
    end;
validate_array_items(_, [], AccRev) ->
    {ok, lists:reverse(AccRev)}.

%% helpers: normalize primitives

normalize_string(S) when is_binary(S) -> {ok, S};
normalize_string(S) when is_list(S) -> {ok, unicode:characters_to_binary(S)};
normalize_string(_) -> {error, <<"invalid_type_expected_string">>}.

normalize_integer(I) when is_integer(I) -> {ok, I};
normalize_integer(B) when is_binary(B) ->
    case catch list_to_integer(binary_to_list(B)) of
        I when is_integer(I) -> {ok, I};
        _ -> {error, <<"invalid_integer_value">>}
    end;
normalize_integer(L) when is_list(L) ->
    case catch list_to_integer(L) of
        I when is_integer(I) -> {ok, I};
        _ -> {error, <<"invalid_integer_value">>}
    end;
normalize_integer(_) -> {error, <<"invalid_type_expected_integer">>}.

normalize_boolean(true) -> {ok, true};
normalize_boolean(false) -> {ok, false};
normalize_boolean(B) when is_binary(B) ->
    case binary:lowercase(B) of
        <<"true">> -> {ok, true};
        <<"false">> -> {ok, false};
        _ -> {error, <<"invalid_boolean_value">>}
    end;
normalize_boolean(L) when is_list(L) ->
    case string:to_lower(L) of
        "true" -> {ok, true};
        "false" -> {ok, false};
        _ -> {error, <<"invalid_boolean_value">>}
    end;
normalize_boolean(_) -> {error, <<"invalid_type_expected_boolean">>}.

%% enum_member compares Value with entries (which can be binary, list, integer, atom)
enum_member(Value, EnumList) ->
    lists:any(fun(E) -> enum_equal(Value, E) end, EnumList).

enum_equal(Bin, E) when is_binary(Bin), is_binary(E) -> Bin =:= E;
enum_equal(Bin, E) when is_binary(Bin), is_list(E) -> Bin =:= unicode:characters_to_binary(E);
enum_equal(Bin, E) when is_binary(Bin), is_atom(E) -> Bin =:= unicode:characters_to_binary(atom_to_list(E));
enum_equal(Int, E) when is_integer(Int), is_integer(E) -> Int =:= E;
enum_equal(Int, E) when is_integer(Int), is_binary(E) ->
    case normalize_integer(E) of
        {ok, EI} -> Int =:= EI;
        _ -> false
    end;
enum_equal(true, E) when is_boolean(E) -> true =:= E;
enum_equal(false, E) when is_boolean(E) -> false =:= E;
enum_equal(Value, E) ->
    try
        Value =:= E
    catch
        _:_ -> false
    end.