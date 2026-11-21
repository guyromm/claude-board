-- Name: pre_request(); Type: FUNCTION; Schema: api; Owner: -
--

CREATE OR REPLACE FUNCTION api.pre_request() RETURNS void
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'board', 'public'
    AS $$
DECLARE c json := nullif(current_setting('request.jwt.claims', true), '')::json;
BEGIN
    -- auth.webgma.co.il token: only for board, with board's grant, for an active human (board.auth_handle)
    IF c ->> 'iss' = 'https://auth.webgma.co.il' THEN
        IF board.auth_handle(c) IS NULL THEN
            RAISE EXCEPTION 'no board access for this auth.webgma.co.il sign-in' USING ERRCODE = '28000',
                HINT = 'ask guy for a board grant at auth.webgma.co.il';
        END IF;
        RETURN;
    END IF;
    IF c IS NULL OR c ->> 'handle' IS NULL THEN RETURN; END IF;   -- anonymous
    IF NOT EXISTS (SELECT 1 FROM agent a WHERE a.handle = c ->> 'handle' AND a.active
                   AND a.token_version = (c ->> 'tv')::int) THEN
        RAISE EXCEPTION 'token revoked or agent inactive' USING ERRCODE = '28000',
            HINT = 'ask the board admin to reissue your token';
    END IF;
END $$;


--
