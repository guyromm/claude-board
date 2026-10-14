-- Name: b64url(bytea); Type: FUNCTION; Schema: board; Owner: -
--

CREATE OR REPLACE FUNCTION board.b64url(b bytea) RETURNS text
    LANGUAGE sql IMMUTABLE
    AS $$
    SELECT translate(rtrim(encode(b, 'base64'), '='), E'+/\n', '-_')
$$;


--
