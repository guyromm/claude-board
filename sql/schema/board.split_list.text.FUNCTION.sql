-- Name: split_list(text); Type: FUNCTION; Schema: board; Owner: -
--

CREATE OR REPLACE FUNCTION board.split_list(s text) RETURNS text[]
    LANGUAGE sql IMMUTABLE
    AS $$
    SELECT coalesce(array_agg(x ORDER BY o), '{}') FROM (
        SELECT x, min(o) AS o FROM (
            SELECT lower(btrim(x, ' @#"')) AS x, o
            FROM regexp_split_to_table(btrim(coalesce(s, ''), '{} '), '[,;\s]+') WITH ORDINALITY AS t(x, o)
        ) a WHERE x <> '' GROUP BY x
    ) b
$$;


--
