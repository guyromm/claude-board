-- Name: review_done(bigint, text, text, text); Type: FUNCTION; Schema: api; Owner: -
--

CREATE OR REPLACE FUNCTION api.review_done(id bigint, status text DEFAULT 'merged'::text, sha text DEFAULT NULL::text, note text DEFAULT NULL::text) RETURNS api."text/plain"
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'board', 'public'
    AS $$
DECLARE me text := board.require_me(); r board.review; st text := lower(btrim(review_done.status));
BEGIN
    SELECT * INTO r FROM review x WHERE x.id = review_done.id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'no review #%', review_done.id; END IF;
    IF me <> r.agent AND NOT board.is_admin() THEN RAISE EXCEPTION 'review #% is %''s', r.id, r.agent USING ERRCODE = '42501'; END IF;
    IF st NOT IN ('merged', 'closed') THEN RAISE EXCEPTION 'status must be merged or closed'; END IF;
    IF st = 'merged' AND r.status <> 'approved' THEN
        RAISE EXCEPTION 'review #% is %, not approved: merge only after guy approves it', r.id, r.status;
    END IF;
    UPDATE review x SET status = st, merged_sha = coalesce(nullif(btrim(review_done.sha), ''), x.merged_sha), updated_at = now(),
           decision_note = coalesce(x.decision_note || E'\n', '') || coalesce(nullif(btrim(review_done.note), ''), '')
    WHERE x.id = r.id;
    PERFORM board.review_clear_flags(r.id);
    RETURN format('review #%s %s -- %s', r.id, st, board.review_url(r.id));
END $$;


--
