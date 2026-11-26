-- Name: watch_sync(text, text, integer, text, text); Type: FUNCTION; Schema: api; Owner: -
--

CREATE OR REPLACE FUNCTION api.watch_sync(session_state text DEFAULT NULL::text, session_detail text DEFAULT NULL::text, version integer DEFAULT NULL::integer, model text DEFAULT NULL::text, claude_version text DEFAULT NULL::text) RETURNS api."text/plain"
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'board', 'public'
    AS $$
DECLARE me text := board.require_me(); l board.login_request; i board.input_request;
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
        watcher_version = coalesce(version, a.watcher_version), last_seen_at = now(),
        claude_model = coalesce(left(nullif(model, ''), 100), a.claude_model),
        claude_version = coalesce(left(nullif(watch_sync.claude_version, ''), 40), a.claude_version),
        claude_info_at = CASE WHEN nullif(model, '') IS NOT NULL OR nullif(watch_sync.claude_version, '') IS NOT NULL
                              THEN now() ELSE a.claude_info_at END
    WHERE a.handle = me;
    PERFORM board.expire_logins();
    SELECT * INTO l FROM board.login_request x
    WHERE x.handle = me AND x.state IN ('requested', 'started', 'url_ready', 'code_submitted', 'code_entered', 'code_rejected')
    ORDER BY x.id DESC LIMIT 1;
    IF NOT FOUND THEN
        -- a queued dialog answer from /agents (10 min to live)
        UPDATE board.input_request x SET state = 'expired', updated_at = now(), message = 'not picked up within 10 min'
         WHERE x.handle = me AND x.state = 'queued' AND x.created_at < now() - interval '10 minutes';
        SELECT * INTO i FROM board.input_request x WHERE x.handle = me AND x.state = 'queued' ORDER BY x.id DESC LIMIT 1;
        IF NOT FOUND THEN RETURN ''; END IF;
        RETURN format(E'input\t%s\t%s\t%s', i.id, i.kind, coalesce(i.value, ''));
    END IF;
    RETURN format(E'login\t%s\t%s\t%s', l.id, l.state, CASE WHEN l.state = 'code_submitted' THEN l.code ELSE '' END);
END $$;


--
