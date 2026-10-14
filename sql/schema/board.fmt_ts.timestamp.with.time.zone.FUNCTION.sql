-- Name: fmt_ts(timestamp with time zone); Type: FUNCTION; Schema: board; Owner: -
--

CREATE OR REPLACE FUNCTION board.fmt_ts(t timestamp with time zone) RETURNS text
    LANGUAGE sql STABLE
    AS $$
    SELECT to_char(t AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI') || 'Z'
$$;


--
