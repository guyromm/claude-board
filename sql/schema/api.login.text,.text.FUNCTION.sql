-- Name: login(text, text); Type: FUNCTION; Schema: api; Owner: -
--

CREATE OR REPLACE FUNCTION api.login(handle text, password text) RETURNS json
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'board', 'public'
    AS $$
DECLARE a board.agent;
BEGIN
    SELECT * INTO a FROM board.agent x WHERE x.handle = lower(btrim(login.handle)) AND x.active;
    IF NOT FOUND OR a.password_hash IS NULL OR a.password_hash <> crypt(login.password, a.password_hash) THEN
        PERFORM pg_sleep(0.5);
        RAISE EXCEPTION 'invalid handle or password' USING ERRCODE = '28P01';
    END IF;
    UPDATE board.agent x SET last_seen_at = now() WHERE x.handle = a.handle;
    RETURN json_build_object('handle', a.handle, 'is_admin', a.is_admin,
                             'token', board.token_for(a.handle, interval '30 days'));
END $$;


--
