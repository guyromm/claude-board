-- Name: poll(integer); Type: FUNCTION; Schema: api; Owner: -
--

CREATE OR REPLACE FUNCTION api.poll(max_lines integer DEFAULT 3) RETURNS api."text/plain"
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'board', 'public'
    AS $$
DECLARE me text := board.require_me(); n integer; lines text; sn integer; slines text;
        tn integer; tlines text; cn integer; clines text; pn integer; plines text; swline text;
BEGIN
    UPDATE board.agent SET last_seen_at = now() WHERE handle = me;
    WITH taken AS (
        UPDATE board.recipient r SET notified_at = now()
        WHERE r.handle = me AND r.notified_at IS NULL AND r.read_at IS NULL AND coalesce(r.deliver_at, '-infinity') <= now()
        RETURNING r.message_id
    )
    SELECT count(*), string_agg(format('[board] message #%s from %s: "%s"%s -- read it with: board read %s',
                                       m.id, m.sender, m.subject,
                                       CASE WHEN cardinality(m.tags) > 0 THEN ' #' || array_to_string(m.tags, ' #') ELSE '' END,
                                       m.id), E'\n' ORDER BY m.id)
    INTO n, lines
    FROM taken t JOIN board.message m ON m.id = t.message_id;
    IF n > max_lines THEN
        lines := format('[board] %s new messages for you -- list them with: board inbox', n);
    END IF;
    -- the summarizer is also prompted for threads with new activity by others (each prompt once)
    IF me = (SELECT summarizer FROM board.policy) THEN
        WITH latest AS (
            SELECT m.thread_id, max(m.id) AS last_id FROM board.message m
            WHERE m.sender <> me GROUP BY m.thread_id
        ), due AS (
            SELECT l.thread_id, l.last_id
            FROM latest l
            JOIN board.message lm ON lm.id = l.last_id
            LEFT JOIN board.thread_summary s ON s.thread_id = l.thread_id
            WHERE l.last_id > coalesce(s.summarized_through, 0) AND l.last_id > coalesce(s.prompted_through, 0)
              AND lm.created_at < now() - (SELECT summary_delay FROM board.policy)
        ), taken AS (
            INSERT INTO board.thread_summary AS s (thread_id, prompted_through, prompted_at)
            SELECT d.thread_id, d.last_id, now() FROM due d
            ON CONFLICT (thread_id) DO UPDATE SET prompted_through = EXCLUDED.prompted_through, prompted_at = now()
            RETURNING s.thread_id, s.prompted_through
        )
        SELECT count(*), string_agg(format(
                   '[board] thread #%s "%s" has new activity (latest #%s from %s) -- summarize it: board thread %s, then board summarize %s --through %s --status open|closed [--human "WHY"] -m "SUMMARY"',
                   t.thread_id, r.subject, t.prompted_through, lm.sender, t.thread_id, t.thread_id, t.prompted_through),
               E'\n' ORDER BY t.thread_id)
        INTO sn, slines
        FROM taken t JOIN board.message r ON r.id = t.thread_id JOIN board.message lm ON lm.id = t.prompted_through;
        IF sn > max_lines THEN
            slines := format('[board] %s threads need a (re)summary -- list them with: board summaries --pending', sn);
        END IF;
    END IF;
    -- tasks newly assigned to me (by someone else)
    WITH taken AS (
        UPDATE board.task t SET assignee_notified_at = now()
        WHERE t.assignee = me AND t.assignee_notified_at IS NULL AND t.status NOT IN ('done', 'cancelled')
        RETURNING t.*
    )
    SELECT count(*), string_agg(format('[board] task #%s "%s" was assigned to you by %s -- see it with: board task %s',
                                       t.id, t.title, coalesce(w.author, t.created_by), t.id), E'\n' ORDER BY t.id)
    INTO tn, tlines
    FROM taken t
    LEFT JOIN LATERAL (SELECT n.author FROM board.task_note n WHERE n.task_id = t.id AND n.change ~ 'assign' ORDER BY n.id DESC LIMIT 1) w ON true
    WHERE coalesce(w.author, t.created_by) <> me;
    IF tn > max_lines THEN
        tlines := format('[board] %s tasks were assigned to you -- list them with: board tasks --mine', tn);
    END IF;
    -- status changes of tasks I own, created, or whose subtask closed (queued by api.task_update)
    WITH taken AS (
        UPDATE board.task_notice x SET notified_at = now()
        WHERE x.handle = me AND x.notified_at IS NULL
        RETURNING x.*
    )
    SELECT count(*), string_agg(t.line, E'\n' ORDER BY t.id) INTO cn, clines FROM taken t;
    IF cn > max_lines THEN
        clines := format('[board] %s of your tasks changed status -- list them with: board tasks --mine', cn);
    END IF;
    -- the PM: open tasks with no activity for their check_every (at most one prompt per check_every), and
    -- tasks that someone else moved to blocked or review
    IF me = (SELECT pm FROM board.policy) THEN
        WITH due AS (
            SELECT t.id FROM board.task t
            WHERE t.status IN ('todo', 'doing', 'blocked', 'review')
              AND ((t.activity_at < now() - t.check_every AND coalesce(t.pm_prompted_at, '-infinity') < now() - t.check_every)
                   OR (t.status IN ('blocked', 'review') AND coalesce(t.pm_prompted_at, '-infinity') < t.status_changed_at
                       AND (SELECT n.author FROM board.task_note n WHERE n.task_id = t.id ORDER BY n.id DESC LIMIT 1) <> me))
        ), taken AS (
            UPDATE board.task t SET pm_prompted_at = now() FROM due WHERE t.id = due.id RETURNING t.*
        )
        SELECT count(*), string_agg(format(
                   '[board] task #%s "%s" [%s, @%s]: %s -- check in: board task %s, then nudge the assignee, re-assign/split it, or escalate (board task update %s --human "WHY")',
                   t.id, t.title, t.status, coalesce(t.assignee, 'unassigned'),
                   CASE WHEN t.status IN ('blocked', 'review') AND t.activity_at >= now() - t.check_every
                        THEN 'moved to ' || t.status ELSE 'no activity for ' || board.fmt_age(now() - t.activity_at) END,
                   t.id, t.id), E'\n' ORDER BY t.id)
        INTO pn, plines
        FROM taken t;
        IF pn > max_lines THEN
            plines := format('[board] %s tasks need a check-in -- list them with: board tasks', pn);
        END IF;
        -- the hourly sweep over every open task (claimed atomically, so one line per period)
        UPDATE board.policy p SET pm_swept_at = now()
        WHERE coalesce(p.pm_swept_at, '-infinity') < now() - p.pm_sweep_every
          AND EXISTS (SELECT 1 FROM board.task t WHERE t.status NOT IN ('done', 'cancelled')
                      AND (NOT t.needs_human OR board.task_human_answered(t.id)));
        IF FOUND THEN
            SELECT format('[board] hourly task sweep, %s open: %s -- for each: board task N (and its threads), judge whether it is moving toward done; if not, nudge whoever can advance it (assignee, or the agent it waits on) with ONE direct message filed under the task, re-assign/split, or escalate (--human). Skip tasks that are moving; note what you checked.',
                          count(*), string_agg(format('#%s %s @%s %s%s', t.id, t.status, coalesce(t.assignee, '-'),
                                                      board.fmt_age(now() - t.activity_at),
                                                      CASE WHEN t.needs_human THEN ' (HUMAN ANSWERED: act on it, then clear --no-human)' ELSE '' END),
                                               ', ' ORDER BY t.needs_human DESC, t.activity_at))
            INTO swline
            FROM board.task t WHERE t.status NOT IN ('done', 'cancelled') AND (NOT t.needs_human OR board.task_human_answered(t.id));
            plines := concat_ws(E'\n', plines, swline);
        END IF;
    END IF;
    RETURN concat_ws(E'\n', lines, slines, tlines, clines, plines);
END $$;


--
