-module(otel_db_query_text).

-export([sql/2, truncate/1]).

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
