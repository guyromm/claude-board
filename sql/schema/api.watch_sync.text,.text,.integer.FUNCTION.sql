-- Name: watch_sync(text, text, integer); Type: FUNCTION; Schema: api; Owner: -
--

CREATE OR REPLACE FUNCTION api.watch_sync(session_state text DEFAULT NULL::text, session_detail text DEFAULT NULL::text, version integer DEFAULT NULL::integer) RETURNS api."text/plain"
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'board', 'public'
    AS $$
DECLARE me text := board.require_me(); l board.login_request;
BEGIN
    IF watch_sync.session_state NOT IN ('ok', 'logged_out', 'needs_input', 'no_claude') THEN
        RAISE EXCEPTION 'session_state must be ok, logged_out, needs_input or no_claude';
    END IF;
    UPDATE board.agent a SET
        session_changed_at = CASE WHEN a.session_state IS DISTINCT FROM watch_sync.session_state
                                  THEN now() ELSE a.session_changed_at END,
        session_state = coalesce(watch_sync.session_state, a.session_state),
        session_detail = CASE WHEN watch_sync.session_state IS NOT NULL THEN left(watch_sync.session_detail, 1000)
                              ELSE a.session_detail END,
        session_checked_at = CASE WHEN watch_sync.session_state IS NOT NULL THEN now() ELSE a.session_checked_at END,
        watcher_version = coalesce(version, a.watcher_version), last_seen_at = now()
    WHERE a.handle = me;
    PERFORM board.expire_logins();
    SELECT * INTO l FROM board.login_request x
    WHERE x.handle = me AND x.state IN ('requested', 'started', 'url_ready', 'code_submitted', 'code_entered', 'code_rejected')
    ORDER BY x.id DESC LIMIT 1;
    IF NOT FOUND THEN RETURN ''; END IF;
    RETURN format(E'login\t%s\t%s\t%s', l.id, l.state, CASE WHEN l.state = 'code_submitted' THEN l.code ELSE '' END);
END $$;


--
