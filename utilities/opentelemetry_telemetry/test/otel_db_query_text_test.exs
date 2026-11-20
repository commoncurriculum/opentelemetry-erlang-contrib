defmodule OtelDbQueryTextTest do
  use ExUnit.Case, async: true

  defp obfuscated(sql), do: :otel_db_query_text.sql(sql, :obfuscated)

  test "the mode follows opt_out_attrs, then query_sanitization" do
    assert :otel_db_query_text.mode(%{opt_out_attrs: [], query_sanitization: true}) == :obfuscated
    assert :otel_db_query_text.mode(%{opt_out_attrs: [], query_sanitization: false}) == :plain

    assert :otel_db_query_text.mode(%{
             opt_out_attrs: [:"db.query.text"],
             query_sanitization: false
           }) ==
             :disabled
  end

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

  defp summary(sql), do: :otel_db_query_text.summary(sql)

  test "a summary names every operation and the tables it touches, in order" do
    assert summary(~s|SELECT o0."id" FROM "oban_jobs" AS o0 WHERE o0."state" = $1|) ==
             {"SELECT oban_jobs", ["oban_jobs"]}

    assert summary(
             "INSERT INTO shipping_details (order_id, address) SELECT order_id, address FROM orders WHERE order_id = 1"
           ) ==
             {"INSERT shipping_details SELECT orders", ["orders", "shipping_details"]}

    assert summary("SELECT * FROM songs s, artists a WHERE s.artist_id = a.id") ==
             {"SELECT songs artists", ["artists", "songs"]}

    assert summary("select * from songs join public.artists on artists.id = songs.artist_id") ==
             {"SELECT songs public.artists", ["public.artists", "songs"]}

    assert summary("UPDATE users SET name = 'FROM x' WHERE id = 1") == {"UPDATE users", ["users"]}

    assert summary("DELETE FROM users WHERE id IN (SELECT id FROM banned)") ==
             {"DELETE users SELECT banned", ["banned", "users"]}
  end

  test "a summary skips subqueries, comments and literals that look like tables" do
    assert summary("SELECT count(*) FROM (SELECT 1 FROM t) AS sub") == {"SELECT SELECT t", ["t"]}
    assert summary("/* FROM a */ SELECT 'FROM b' -- FROM c\n FROM d") == {"SELECT d", ["d"]}

    assert summary("SELECT * FROM generate_series(1, 10)") ==
             {"SELECT generate_series", ["generate_series"]}
  end

  test "a summary names statements that touch no table" do
    assert summary("BEGIN") == {"BEGIN", []}
    assert summary("SELECT 1") == {"SELECT", []}
    assert summary("TRUNCATE TABLE events") == {"TRUNCATE events", ["events"]}
    assert summary("COPY users FROM STDIN") == {"COPY users", ["users"]}
    assert summary("WITH x AS (SELECT 1) SELECT * FROM x") == {"SELECT SELECT x", ["x"]}
    assert summary("EXPLAIN") == {:undefined, []}
  end

  test "a summary is cut to 255 bytes" do
    tables = Enum.map_join(1..100, ", ", &"table_#{&1}")
    assert {summary, _tables} = summary("SELECT * FROM " <> tables)
    assert byte_size(summary) == 255
  end

  test "attributes name the collection only when the statement names one table, as written there" do
    assert :otel_db_query_text.attributes(
             "SELECT * FROM users WHERE id = 1",
             "users",
             :obfuscated
           ) ==
             {%{"db.query.summary": "SELECT users", "db.collection.name": "users"},
              %{"db.query.text": "SELECT * FROM users WHERE id = ?"}}

    assert :otel_db_query_text.attributes(~s(SELECT * FROM "other"."users"), "users", :disabled) ==
             {%{"db.query.summary": "SELECT other.users", "db.collection.name": "other.users"},
              %{}}

    assert :otel_db_query_text.attributes("SELECT 1", "users", :disabled) ==
             {%{"db.query.summary": "SELECT", "db.collection.name": "users"}, %{}}

    assert :otel_db_query_text.attributes("SELECT * FROM a JOIN b ON a.id = b.id", "a", :disabled) ==
             {%{"db.query.summary": "SELECT a b"}, %{}}

    assert :otel_db_query_text.attributes("VALUES (1)", nil, :plain) ==
             {%{}, %{"db.query.text": "VALUES (1)"}}
  end
end
