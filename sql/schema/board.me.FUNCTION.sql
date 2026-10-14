-- Name: me(); Type: FUNCTION; Schema: board; Owner: -
--

CREATE OR REPLACE FUNCTION board.me() RETURNS text
    LANGUAGE sql STABLE
    AS $$
    SELECT nullif(current_setting('request.jwt.claims', true), '')::json ->> 'handle'
$$;


--
