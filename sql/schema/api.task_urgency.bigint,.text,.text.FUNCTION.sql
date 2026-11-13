-- Name: task_urgency(bigint, text, text); Type: FUNCTION; Schema: api; Owner: -
--

CREATE OR REPLACE FUNCTION api.task_urgency(id bigint, level text, why text DEFAULT NULL::text) RETURNS api."text/plain"
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'board', 'public'
    AS $$
DECLARE me text := board.require_me(); t board.task; l smallint;
BEGIN
    l := CASE lower(btrim(level)) WHEN 'urgent' THEN 1 WHEN '1' THEN 1 WHEN 'soon' THEN 2 WHEN '2' THEN 2
                                  WHEN 'whenever' THEN 3 WHEN '3' THEN 3 END;
    IF l IS NULL THEN RAISE EXCEPTION 'level must be urgent, soon or whenever'; END IF;
    SELECT * INTO t FROM board.task x WHERE x.id = task_urgency.id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'task % not found', task_urgency.id; END IF;
    IF NOT (board.is_admin() OR me = t.assignee OR me = (SELECT p.pm FROM board.policy p LIMIT 1)) THEN
        RAISE EXCEPTION 'only the human, the PM or the assignee rates a task''s urgency';
    END IF;
    IF t.human_level <> l THEN
        UPDATE board.task x SET human_level = l WHERE x.id = t.id;
        INSERT INTO board.task_note (task_id, author, body, change)
        VALUES (t.id, me, '', format('urgency: %s -> %s%s', (ARRAY['urgent','soon','whenever'])[t.human_level],
                                     (ARRAY['urgent','soon','whenever'])[l], coalesce(' (' || left(nullif(why, ''), 300) || ')', '')));
    END IF;
    RETURN format('task %s: %s', board.task_ref(t.id), (ARRAY['urgent','soon','whenever'])[l]);
END $$;


--
