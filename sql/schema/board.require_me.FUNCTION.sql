-- Name: require_me(); Type: FUNCTION; Schema: board; Owner: -
--

CREATE OR REPLACE FUNCTION board.require_me() RETURNS text
    LANGUAGE plpgsql STABLE
    AS $$
DECLARE h text := board.me();
BEGIN
    IF h IS NULL THEN RAISE EXCEPTION 'authentication required' USING ERRCODE = '28000'; END IF;
    RETURN h;
END $$;


--
