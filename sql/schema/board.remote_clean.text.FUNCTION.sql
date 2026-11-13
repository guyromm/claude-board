-- Name: remote_clean(text); Type: FUNCTION; Schema: board; Owner: -
--

CREATE OR REPLACE FUNCTION board.remote_clean(u text) RETURNS text
    LANGUAGE sql IMMUTABLE
    AS $$
    SELECT nullif(regexp_replace(btrim(coalesce(u, '')), '^(https?://)[^/@]+@', '\1'), '')
$$;


--
