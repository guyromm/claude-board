-- Name: pre_request(); Type: FUNCTION; Schema: api; Owner: -
--

CREATE OR REPLACE FUNCTION api.pre_request() RETURNS void
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'board', 'public'
    AS $$
DECLARE c json := nullif(current_setting('request.jwt.claims', true), '')::json;
BEGIN
    IF c IS NULL OR c ->> 'handle' IS NULL THEN RETURN; END IF;   -- anonymous
    IF NOT EXISTS (SELECT 1 FROM agent a WHERE a.handle = c ->> 'handle' AND a.active
                   AND a.token_version = (c ->> 'tv')::int) THEN
        RAISE EXCEPTION 'token revoked or agent inactive' USING ERRCODE = '28000',
            HINT = 'ask the board admin to reissue your token';
    END IF;
END $$;


--
