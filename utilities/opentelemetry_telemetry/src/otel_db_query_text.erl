-module(otel_db_query_text).

-export([sql/2, truncate/1, summary/1]).

-define(MAX_BYTES, 2048).

%% Comments, quoted identifiers and parameters are matched so that a quote or digit inside them
%% is never taken for a literal; only the `literal' group is replaced.
-define(SQL_TOKENS,
        "--[^\\n]*"
        "|/\\*[\\s\\S]*?\\*/"
        "|\"(?:[^\"]|\"\")*\""
        "|`(?:[^`]|``)*`"
        "|\\$\\d+"
        "|\\{[^{}']*\\}"
        "|[A-Za-z_][A-Za-z0-9_$]*"
        "|(?<literal>"
        "'(?:[^'\\\\]|''|\\\\.)*'"
        "|\\$([A-Za-z_][A-Za-z0-9_]*|)\\$[\\s\\S]*?\\$\\g{-1}\\$"
        "|0[xX][0-9A-Fa-f]+"
        "|(?:\\d+\\.?\\d*|\\.\\d+)(?:[eE][+-]?\\d+)?"
        ")").

-spec sql(iodata(), plain | obfuscated) -> binary().
sql(Statement, plain) ->
    truncate(iolist_to_binary(Statement));
sql(Statement, obfuscated) ->
    truncate(obfuscate(iolist_to_binary(Statement))).

-spec truncate(binary()) -> binary().
truncate(<<Text:?MAX_BYTES/binary, _/binary>>) ->
    valid_prefix(Text);
truncate(Text) ->
    Text.

obfuscate(Sql) ->
    case re:run(Sql, mp(), [global, {capture, [literal], index}]) of
        {match, Matches} -> replace(Sql, [Span || [{Start, _} = Span] <- Matches, Start >= 0], 0);
        nomatch -> Sql
    end.

replace(Sql, [], Offset) ->
    binary:part(Sql, Offset, byte_size(Sql) - Offset);
replace(Sql, [{Start, Length} | Literals], Offset) ->
    Before = binary:part(Sql, Offset, Start - Offset),
    Rest = replace(Sql, Literals, Start + Length),
    <<Before/binary, "?", Rest/binary>>.

valid_prefix(Text) ->
    case unicode:characters_to_binary(Text) of
        Text -> Text;
        _ -> valid_prefix(binary:part(Text, 0, byte_size(Text) - 1))
    end.

mp() ->
    case persistent_term:get({?MODULE, mp}, undefined) of
        undefined ->
            {ok, MP} = re:compile(?SQL_TOKENS, [unicode]),
            persistent_term:put({?MODULE, mp}, MP),
            MP;
        MP ->
            MP
    end.

%% db.query.summary, following the semantic conventions' "Generating a summary": every
%% operation in the order it appears, each followed by the tables it names, cut to 255 bytes.
%% Returns the summary, or undefined when the statement names no operation, and the tables.
-spec summary(iodata()) -> {binary() | undefined, [binary()]}.
summary(Statement) ->
    Sql = iolist_to_binary(Statement),
    Tokens =
        case re:run(Sql, summary_mp(), [global, {capture, [token], binary}]) of
            {match, Matches} -> [T || [T] <- Matches, T =/= <<>>];
            nomatch -> []
        end,
    Parts = parts(Tokens, start, []),
    Tables = lists:usort([P || {table, P} <- Parts]),
    case [P || {_, P} <- Parts] of
        [] -> {undefined, Tables};
        Words -> {truncate_summary(iolist_to_binary(lists:join(<<" ">>, Words))), Tables}
    end.

-define(SUMMARY_TOKENS,
        "--[^\\n]*"
        "|/\\*[\\s\\S]*?\\*/"
        "|'(?:[^'\\\\]|''|\\\\.)*'"
        "|\\$([A-Za-z_][A-Za-z0-9_]*|)\\$[\\s\\S]*?\\$\\g{-1}\\$"
        "|(?<token>"
        "(?:\"(?:[^\"]|\"\")*\"|`(?:[^`]|``)*`|[A-Za-z_][A-Za-z0-9_$]*)"
        "(?:\\s*\\.\\s*(?:\"(?:[^\"]|\"\")*\"|`(?:[^`]|``)*`|[A-Za-z_][A-Za-z0-9_$]*))*"
        "|[(),;]"
        ")").

%% Expect is what the next token may be: {table, Mode} after FROM, JOIN, INTO, UPDATE, TABLE or
%% COPY, where Mode is list when a comma may name another table (FROM) and single otherwise;
%% {list, Depth} after a table of a FROM list, Depth being the parentheses opened since; or none.
parts([], _Expect, Acc) ->
    lists:reverse(Acc);
parts([Token | Rest], Expect, Acc) ->
    Word = string:uppercase(Token),
    case {Expect, Word} of
        {_, <<";">>} ->
            parts(Rest, start, Acc);
        {{table, _}, <<"(">>} ->
            parts(Rest, none, Acc);
        {{table, _}, _} when Word =:= <<"ONLY">>; Word =:= <<"IF">>; Word =:= <<"NOT">>;
                             Word =:= <<"EXISTS">>; Word =:= <<"LATERAL">>;
                             Word =:= <<"TABLE">> ->
            parts(Rest, Expect, Acc);
        {{table, Mode}, _} ->
            case is_keyword(Word) orelse not is_identifier(Token) of
                true ->
                    parts([Token | Rest], none, Acc);
                false ->
                    Next = case Mode of list -> {list, 0}; single -> none; rest -> rest end,
                    parts(Rest, Next, [{table, unquote(Token)} | Acc])
            end;
        {{list, Depth}, <<"(">>} ->
            parts(Rest, {list, Depth + 1}, Acc);
        {{list, 0}, <<")">>} ->
            parts(Rest, none, Acc);
        {{list, Depth}, <<")">>} ->
            parts(Rest, {list, Depth - 1}, Acc);
        {{list, 0}, <<",">>} ->
            parts(Rest, {table, list}, Acc);
        {{list, 0}, _} ->
            case is_keyword(Word) of
                true -> parts([Token | Rest], none, Acc);
                false -> parts(Rest, Expect, Acc)
            end;
        {{list, _}, _} ->
            parts(Rest, Expect, Acc);
        {rest, _} ->
            parts(Rest, rest, Acc);
        {start, _} ->
            case operation(Word) of
                {Operation, Next} -> parts(Rest, Next, [{operation, Operation} | Acc]);
                undefined -> parts([Token | Rest], none, Acc)
            end;
        {none, _} ->
            case nested_operation(Word) of
                {Operation, Next} ->
                    parts(Rest, Next, [{operation, Operation} | Acc]);
                undefined when Word =:= <<"FROM">>; Word =:= <<"JOIN">>; Word =:= <<"USING">> ->
                    parts(Rest, {table, list}, Acc);
                undefined when Word =:= <<"INTO">>; Word =:= <<"TABLE">> ->
                    parts(Rest, {table, single}, Acc);
                undefined ->
                    parts(Rest, none, Acc)
            end
    end.

%% Operations that may appear inside a statement, such as a subquery's SELECT.
nested_operation(Word) ->
    case Word of
        <<"SELECT">> -> {Word, none};
        <<"INSERT">> -> {Word, none};
        <<"UPDATE">> -> {Word, {table, single}};
        <<"DELETE">> -> {Word, none};
        <<"MERGE">> -> {Word, none};
        _ -> undefined
    end.

%% Operations a statement may start with.
operation(Word) ->
    case Word of
        <<"SELECT">> -> {Word, none};
        <<"INSERT">> -> {Word, none};
        <<"UPDATE">> -> {Word, {table, single}};
        <<"DELETE">> -> {Word, none};
        <<"MERGE">> -> {Word, none};
        <<"COPY">> -> {Word, {table, rest}};
        <<"TRUNCATE">> -> {Word, {table, single}};
        <<"CREATE">> -> {Word, none};
        <<"ALTER">> -> {Word, none};
        <<"DROP">> -> {Word, none};
        <<"BEGIN">> -> {Word, none};
        <<"COMMIT">> -> {Word, none};
        <<"ROLLBACK">> -> {Word, none};
        <<"SAVEPOINT">> -> {Word, none};
        <<"RELEASE">> -> {Word, none};
        <<"SET">> -> {Word, none};
        <<"SHOW">> -> {Word, none};
        <<"LISTEN">> -> {Word, none};
        <<"UNLISTEN">> -> {Word, none};
        <<"NOTIFY">> -> {Word, none};
        <<"CALL">> -> {Word, none};
        <<"VACUUM">> -> {Word, none};
        <<"ANALYZE">> -> {Word, none};
        <<"OPTIMIZE">> -> {Word, {table, single}};
        <<"EXCHANGE">> -> {Word, none};
        <<"SYSTEM">> -> {Word, none};
        _ -> undefined
    end.

is_keyword(Word) ->
    operation(Word) =/= undefined orelse
        lists:member(Word, [
            <<"FROM">>, <<"JOIN">>, <<"INNER">>, <<"LEFT">>, <<"RIGHT">>, <<"FULL">>,
            <<"OUTER">>, <<"CROSS">>, <<"NATURAL">>, <<"ON">>, <<"WHERE">>, <<"GROUP">>,
            <<"ORDER">>, <<"HAVING">>, <<"LIMIT">>, <<"OFFSET">>, <<"UNION">>,
            <<"INTERSECT">>, <<"EXCEPT">>, <<"RETURNING">>, <<"VALUES">>, <<"FORMAT">>,
            <<"SETTINGS">>, <<"WINDOW">>, <<"FINAL">>, <<"SAMPLE">>, <<"PREWHERE">>,
            <<"ARRAY">>, <<"FOR">>, <<"USING">>, <<"INTO">>, <<"AS">>, <<"WITH">>,
            <<"DEFAULT">>, <<"SELECT">>
        ]).

is_identifier(<<C, _/binary>>) when C =:= $"; C =:= $`; C =:= $_ -> true;
is_identifier(<<C, _/binary>>) when C >= $a, C =< $z; C >= $A, C =< $Z -> true;
is_identifier(_) -> false.

unquote(Name) ->
    iolist_to_binary([unquote_part(P) || P <- re:split(Name, <<"\\s*(\\.)\\s*">>, [{return, binary}, trim])]).

unquote_part(<<"\"", _/binary>> = Part) ->
    binary:replace(binary:part(Part, 1, byte_size(Part) - 2), <<"\"\"">>, <<"\"">>, [global]);
unquote_part(<<"`", _/binary>> = Part) ->
    binary:replace(binary:part(Part, 1, byte_size(Part) - 2), <<"``">>, <<"`">>, [global]);
unquote_part(Part) ->
    Part.

truncate_summary(<<Summary:255/binary, _/binary>>) -> valid_prefix(Summary);
truncate_summary(Summary) -> Summary.

summary_mp() ->
    case persistent_term:get({?MODULE, summary_mp}, undefined) of
        undefined ->
            {ok, MP} = re:compile(?SUMMARY_TOKENS, [unicode]),
            persistent_term:put({?MODULE, summary_mp}, MP),
            MP;
        MP ->
            MP
    end.
