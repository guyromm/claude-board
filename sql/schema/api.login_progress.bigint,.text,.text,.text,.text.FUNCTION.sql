-- Name: login_progress(bigint, text, text, text, text); Type: FUNCTION; Schema: api; Owner: -
--

CREATE OR REPLACE FUNCTION api.login_progress(id bigint, state text, url text DEFAULT NULL::text, message text DEFAULT NULL::text, pane_tail text DEFAULT NULL::text) RETURNS api."text/plain"
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'board', 'public'
    AS $$
DECLARE me text := board.require_me(); cur board.login_request; keep boolean;
BEGIN
    SELECT * INTO cur FROM board.login_request x WHERE x.id = login_progress.id AND x.handle = me FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'login request #% not found for %', login_progress.id, me; END IF;
    IF cur.state IN ('succeeded', 'failed', 'expired', 'cancelled') THEN
        RETURN 'closed:' || cur.state;     -- e.g. cancelled by the human meanwhile: the watcher stops
    END IF;
    IF login_progress.state NOT IN ('started', 'url_ready', 'code_entered', 'code_rejected', 'succeeded', 'failed', 'expired') THEN
        RAISE EXCEPTION 'bad state %', login_progress.state;
    END IF;
    keep := cur.state = 'code_submitted' AND login_progress.state IN ('started', 'url_ready');
    UPDATE board.login_request x SET
        -- a late URL report must not undo a code the human has just submitted
        state = CASE WHEN keep THEN x.state ELSE login_progress.state END,
        code = CASE WHEN keep THEN x.code END,
        url = coalesce(login_progress.url, x.url),
        message = CASE WHEN keep THEN x.message ELSE coalesce(left(login_progress.message, 500), x.message) END,
        pane_tail = coalesce(left(login_progress.pane_tail, 4000), x.pane_tail),
        updated_at = now()
    WHERE x.id = cur.id;
    IF login_progress.state = 'succeeded' THEN
        UPDATE board.agent SET session_state = 'ok', session_detail = 'logged in via the board', session_changed_at = now()
        WHERE handle = me;
    END IF;
    RETURN 'ok';
END $$;


--
