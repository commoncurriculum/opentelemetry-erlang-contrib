defmodule OtelDbQueryTextTest do
  use ExUnit.Case, async: true

  defp obfuscated(sql), do: :otel_db_query_text.sql(sql, :obfuscated)

  test "obfuscated SQL replaces each literal with ?" do
    assert obfuscated("SELECT * FROM users WHERE email = 'ada@example.com' AND age > 42") ==
             "SELECT * FROM users WHERE email = ? AND age > ?"

    assert obfuscated("SELECT 'it''s', 'a\\'b', 2.5, .5, 1e10, 0xFF, $tag$ x $ y $tag$, $$z$$") ==
             "SELECT ?, ?, ?, ?, ?, ?, ?, ?"
  end

  test "obfuscated SQL keeps identifiers, parameters and comments" do
    sql =
      ~s|SELECT "col 1", `col 2`, t2.x, $1, {id:UInt64} FROM t2 /* it's 1 */ -- don't 2\n| <>
        "WHERE x = $2"

    assert obfuscated(sql) == sql
  end

  test "text is cut to its first 2048 bytes without splitting a character" do
    text = :otel_db_query_text.sql(String.duplicate("é", 2_000), :plain)

    assert byte_size(text) == 2048
    assert String.valid?(text)
    assert :otel_db_query_text.truncate("short") == "short"
    assert byte_size(:otel_db_query_text.truncate("a" <> String.duplicate("é", 2_000))) == 2047
  end
end
