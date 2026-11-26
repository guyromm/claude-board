-- Name: send_session_input(text, text, text); Type: FUNCTION; Schema: api; Owner: -
--

CREATE OR REPLACE FUNCTION api.send_session_input(handle text, kind text, value text DEFAULT NULL::text) RETURNS json
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'board', 'public'
    AS $_$
DECLARE me text := board.require_admin(); a board.agent; v text := nullif(btrim(send_session_input.value), ''); new_id bigint;
BEGIN
    SELECT * INTO a FROM board.agent x WHERE x.handle = send_session_input.handle;
    IF NOT FOUND OR a.kind <> 'agent' THEN RAISE EXCEPTION 'no agent "%"', send_session_input.handle; END IF;
    IF coalesce(a.watcher_version, 0) < 30 THEN
        RAISE EXCEPTION '%''s watcher (v%) is too old to answer dialogs from the board', a.handle, coalesce(a.watcher_version, 0)
            USING HINT = 'it self-upgrades within 5 minutes of a new version; answer in its tmux pane meanwhile';
    END IF;
    IF a.session_state IS DISTINCT FROM 'needs_input' THEN
        RAISE EXCEPTION '%''s session shows no open dialog (%)', a.handle, coalesce(a.session_state, '?');
    END IF;
    IF send_session_input.kind = 'choice' THEN
        IF v IS NULL OR v !~ '^[1-9]$' THEN RAISE EXCEPTION 'choice must be one option number, 1-9'; END IF;
    ELSIF send_session_input.kind = 'text' THEN
        IF v IS NULL THEN RAISE EXCEPTION 'empty text'; END IF;
        IF length(v) > 2000 THEN RAISE EXCEPTION 'text is longer than 2000 characters'; END IF;
        IF v ~ '[[:cntrl:]]' THEN RAISE EXCEPTION 'one line only: no newlines, tabs or control characters'; END IF;
    ELSIF send_session_input.kind = 'escape' THEN v := NULL;
    ELSE RAISE EXCEPTION 'kind must be choice, text or escape';
    END IF;
    UPDATE board.input_request x SET state = 'cancelled', updated_at = now(), message = 'replaced by a newer answer'
     WHERE x.handle = a.handle AND x.state = 'queued';
    INSERT INTO board.input_request (handle, requested_by, kind, value) VALUES (a.handle, me, send_session_input.kind, v)
    RETURNING id INTO new_id;
    RETURN json_build_object('id', new_id);
END $_$;


--
