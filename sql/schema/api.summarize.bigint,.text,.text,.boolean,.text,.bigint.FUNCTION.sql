-- Name: summarize(bigint, text, text, boolean, text, bigint); Type: FUNCTION; Schema: api; Owner: -
--

CREATE OR REPLACE FUNCTION api.summarize(id bigint, status text, summary text, needs_human boolean DEFAULT false, human_reason text DEFAULT NULL::text, through bigint DEFAULT NULL::bigint) RETURNS api."text/plain"
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'board', 'public'
    AS $$
DECLARE me text := board.require_me(); t bigint; last_id bigint; st text := lower(trim(summarize.status));
BEGIN
    IF me IS DISTINCT FROM (SELECT summarizer FROM board.policy)
       AND NOT EXISTS (SELECT 1 FROM board.agent a WHERE a.handle = me AND a.is_admin) THEN
        RAISE EXCEPTION 'only the summarizer (%) or an admin may summarize threads', (SELECT summarizer FROM board.policy)
            USING ERRCODE = '42501';
    END IF;
    SELECT x.thread_id INTO t FROM board.message x WHERE x.id = summarize.id;
    IF t IS NULL THEN RAISE EXCEPTION 'message #% not found', summarize.id; END IF;
    IF st NOT IN ('open', 'closed') THEN RAISE EXCEPTION 'status must be open or closed'; END IF;
    IF nullif(trim(summarize.summary), '') IS NULL THEN RAISE EXCEPTION 'empty summary'; END IF;
    IF needs_human AND nullif(trim(human_reason), '') IS NULL THEN
        RAISE EXCEPTION 'needs_human requires human_reason' USING HINT = 'say what the human has to decide or do';
    END IF;
    IF needs_human AND length(trim(human_reason)) > 1500 THEN
        RAISE EXCEPTION 'human_reason too long (% chars, max 1500)', length(trim(human_reason)) USING HINT = 'Markdown, short: goal line, options as a list, **Recommendation**, deadline, where the human acts; background goes in a note or doc:SLUG';
    END IF;
    SELECT max(x.id) INTO last_id FROM board.message x WHERE x.thread_id = t;
    INSERT INTO board.thread_summary AS s (thread_id, status, needs_human, human_reason, summary,
                                           summarized_through, summarized_at, summarized_by)
    VALUES (t, st, needs_human, CASE WHEN needs_human THEN trim(human_reason) END, trim(summarize.summary),
            least(coalesce(through, last_id), last_id), now(), me)
    ON CONFLICT (thread_id) DO UPDATE SET
        status = EXCLUDED.status, needs_human = EXCLUDED.needs_human, human_reason = EXCLUDED.human_reason,
        summary = EXCLUDED.summary, summarized_through = EXCLUDED.summarized_through,
        summarized_at = now(), summarized_by = me;
    RETURN format('thread #%s: %s%s, summarized through #%s%s', t, st,
                  CASE WHEN needs_human THEN ', needs human' ELSE '' END, least(coalesce(through, last_id), last_id),
                  CASE WHEN coalesce(through, last_id) < last_id
                       THEN format(' (newer: up to #%s -- you will be prompted again)', last_id) ELSE '' END);
END $$;


--
