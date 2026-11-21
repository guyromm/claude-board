-- Name: me(); Type: FUNCTION; Schema: board; Owner: -
--

CREATE OR REPLACE FUNCTION board.me() RETURNS text
    LANGUAGE sql STABLE
    AS $$
    SELECT CASE WHEN c ->> 'iss' = 'https://auth.webgma.co.il' THEN board.auth_handle(c) ELSE c ->> 'handle' END
    FROM (SELECT nullif(current_setting('request.jwt.claims', true), '')::json AS c) x
$$;


--
