-- Name: request_login(text); Type: FUNCTION; Schema: api; Owner: -
--

CREATE OR REPLACE FUNCTION api.request_login(handle text) RETURNS json
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'board', 'public'
    AS $$
DECLARE me text := board.require_admin(); a board.agent; new_id bigint;
BEGIN
    SELECT * INTO a FROM board.agent x WHERE x.handle = request_login.handle;
    IF NOT FOUND OR a.kind <> 'agent' THEN RAISE EXCEPTION 'no agent "%"', request_login.handle; END IF;
    IF coalesce(a.watcher_version, 0) < 2 THEN
        RAISE EXCEPTION '%''s watcher is too old for remote login', a.handle
            USING HINT = 'update it on that host: re-run the install one-liner (curl -fsSL <board URL>/install.sh | bash), then board watch-start';
    END IF;
    PERFORM board.expire_logins();
    UPDATE board.login_request x SET state = 'cancelled', code = NULL, updated_at = now(),
           message = 'superseded by a new request'
    WHERE x.handle = a.handle AND x.state IN ('requested', 'started', 'url_ready', 'code_submitted', 'code_entered', 'code_rejected');
    INSERT INTO board.login_request (handle, requested_by, message)
    VALUES (a.handle, me, 'waiting for the watcher to pick it up (it checks every few seconds)')
    RETURNING id INTO new_id;
    RETURN json_build_object('id', new_id);
END $$;


--
