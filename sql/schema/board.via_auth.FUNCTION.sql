-- Name: via_auth(); Type: FUNCTION; Schema: board; Owner: -
--

CREATE OR REPLACE FUNCTION board.via_auth() RETURNS boolean
    LANGUAGE sql STABLE
    AS $$
    SELECT coalesce(nullif(current_setting('request.jwt.claims', true), '')::json ->> 'iss' = 'https://auth.webgma.co.il'
                    AND board.me() IS NOT NULL, false)
$$;


--
