-- Name: task_update(bigint, text, text, text, text, text, bigint, text, text, boolean, text, double precision); Type: FUNCTION; Schema: api; Owner: -
--

CREATE OR REPLACE FUNCTION api.task_update(id bigint, status text DEFAULT NULL::text, note text DEFAULT NULL::text, assignee text DEFAULT NULL::text, title text DEFAULT NULL::text, description text DEFAULT NULL::text, parent bigint DEFAULT NULL::bigint, check_every text DEFAULT NULL::text, due text DEFAULT NULL::text, needs_human boolean DEFAULT NULL::boolean, human_reason text DEFAULT NULL::text, "position" double precision DEFAULT NULL::double precision) RETURNS api."text/plain"
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'board', 'public'
    AS $$
DECLARE
    me text := board.require_me();
    o board.task; n board.task;
    who text := nullif(lower(btrim(task_update.assignee, ' @')), '');
    changes text[] := '{}';
    edits boolean;
BEGIN
    SELECT * INTO o FROM board.task x WHERE x.id = task_update.id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'task #% not found', task_update.id; END IF;
    n := o;
    edits := coalesce(task_update.status, who, task_update.title, task_update.description, task_update.parent::text,
                      task_update.check_every, task_update.due, task_update.needs_human::text, task_update."position"::text) IS NOT NULL;
    IF edits AND NOT board.task_can_edit(o.id, me) THEN
        RAISE EXCEPTION 'task #%: only its assignee, its creator, the assignee of a parent task, the PM or an admin may change it', o.id
            USING ERRCODE = '42501', HINT = 'add a note instead: board task note ID -m "..."';
    END IF;
    IF task_update.status IS NOT NULL THEN n.status := board.task_status(task_update.status); END IF;
    IF o.status = 'ongoing' AND n.status IN ('review', 'done') THEN
        RAISE EXCEPTION 'task #% is ongoing maintenance: it never completes', o.id
            USING HINT = 'report a problem with a note or --status blocked; retire it with --status cancelled';
    END IF;
    IF who = '-' THEN n.assignee := NULL;
    ELSIF who IS NOT NULL THEN
        IF NOT EXISTS (SELECT 1 FROM board.agent a WHERE a.handle = who) THEN
            RAISE EXCEPTION 'unknown assignee "%"', who USING HINT = 'list participants with: board agents';
        END IF;
        n.assignee := who;
    END IF;
    IF nullif(btrim(task_update.title), '') IS NOT NULL THEN n.title := btrim(task_update.title); END IF;
    IF task_update.description IS NOT NULL THEN n.description := task_update.description; END IF;
    IF task_update.parent = 0 THEN n.parent_id := NULL;
    ELSIF task_update.parent IS NOT NULL THEN
        IF NOT EXISTS (SELECT 1 FROM board.task x WHERE x.id = task_update.parent) THEN
            RAISE EXCEPTION 'parent task #% not found', task_update.parent;
        END IF;
        IF EXISTS (WITH RECURSIVE up AS (SELECT x.id, x.parent_id FROM board.task x WHERE x.id = task_update.parent
                                         UNION ALL SELECT p.id, p.parent_id FROM board.task p JOIN up ON p.id = up.parent_id)
                   SELECT 1 FROM up WHERE up.id = o.id) THEN
            RAISE EXCEPTION 'task #% can''t be under #%: that would make a cycle', o.id, task_update.parent;
        END IF;
        n.parent_id := task_update.parent;
    END IF;
    IF nullif(task_update.check_every, '') IS NOT NULL THEN n.check_every := board.task_interval(task_update.check_every); END IF;
    IF task_update.due = '-' THEN n.due_at := NULL; ELSIF nullif(task_update.due, '') IS NOT NULL THEN n.due_at := task_update.due::timestamptz; END IF;
    IF task_update.needs_human IS NOT NULL THEN
        IF task_update.needs_human AND nullif(btrim(task_update.human_reason), '') IS NULL THEN
            RAISE EXCEPTION 'needs_human requires human_reason' USING HINT = 'say what the human has to decide or do';
        END IF;
        n.needs_human := task_update.needs_human;
        n.human_reason := CASE WHEN task_update.needs_human THEN btrim(task_update.human_reason) END;
    END IF;
    IF task_update."position" IS NOT NULL THEN n.position := task_update."position"; END IF;
    -- closing a task settles its escalation
    IF n.status IN ('done', 'cancelled') AND n.status IS DISTINCT FROM o.status AND n.needs_human
       AND task_update.needs_human IS NULL THEN
        n.needs_human := false; n.human_reason := NULL;
    END IF;

    IF n.status IS DISTINCT FROM o.status THEN changes := changes || format('status: %s -> %s', o.status, n.status); END IF;
    IF n.assignee IS DISTINCT FROM o.assignee THEN
        changes := changes || format('assignee: %s -> %s', coalesce(o.assignee, '-'), coalesce(n.assignee, '-'));
    END IF;
    IF n.title IS DISTINCT FROM o.title THEN changes := changes || format('title: "%s"', n.title); END IF;
    IF n.description IS DISTINCT FROM o.description THEN changes := changes || 'description edited'::text; END IF;
    IF n.parent_id IS DISTINCT FROM o.parent_id THEN changes := changes || format('parent: %s', coalesce('#' || n.parent_id, '-')); END IF;
    IF n.check_every IS DISTINCT FROM o.check_every THEN changes := changes || format('check-in every %s', n.check_every); END IF;
    IF n.due_at IS DISTINCT FROM o.due_at THEN changes := changes || format('due: %s', coalesce(board.fmt_ts(n.due_at), '-')); END IF;
    IF n.needs_human IS DISTINCT FROM o.needs_human OR n.human_reason IS DISTINCT FROM o.human_reason THEN
        changes := changes || CASE WHEN n.needs_human THEN 'escalated to the human: ' || n.human_reason ELSE 'escalation cleared' END;
    END IF;
    IF cardinality(changes) = 0 AND nullif(btrim(task_update.note), '') IS NULL THEN
        IF n.position IS DISTINCT FROM o.position THEN
            UPDATE board.task x SET position = n.position WHERE x.id = o.id;
            RETURN format('task #%s moved', o.id);
        END IF;
        RETURN format('task #%s: nothing changed', o.id);
    END IF;

    UPDATE board.task x SET status = n.status, assignee = n.assignee, title = n.title, description = n.description,
        parent_id = n.parent_id, check_every = n.check_every, due_at = n.due_at, needs_human = n.needs_human,
        human_reason = n.human_reason, position = n.position, updated_at = now(), activity_at = now(),
        status_changed_at = CASE WHEN n.status IS DISTINCT FROM o.status THEN now() ELSE x.status_changed_at END,
        assignee_notified_at = CASE WHEN n.assignee IS DISTINCT FROM o.assignee THEN NULL ELSE x.assignee_notified_at END
    WHERE x.id = o.id RETURNING * INTO n;
    INSERT INTO board.task_note (task_id, author, body, change)
    VALUES (o.id, me, coalesce(btrim(task_update.note), ''), nullif(array_to_string(changes, '; '), ''));
    -- tell the people who depend on it about a status change (the PM's own blocked/review prompts and a
    -- new assignee's assignment notice already cover those)
    IF n.status IS DISTINCT FROM o.status THEN
        INSERT INTO board.task_notice (task_id, handle, line)
        SELECT DISTINCT ON (r.handle) o.id, r.handle, format('[board] task #%s "%s" moved %s -> %s by %s%s%s -- see it with: board task %s',
               o.id, n.title, o.status, n.status, me,
               CASE WHEN r.why = 'parent' THEN format(' (subtask of #%s "%s")', p.id, p.title) ELSE '' END,
               CASE WHEN nullif(btrim(task_update.note), '') IS NOT NULL
                    THEN ': "' || left(regexp_replace(btrim(task_update.note), '\s+', ' ', 'g'), 150)
                         || CASE WHEN length(btrim(task_update.note)) > 150 THEN '…' ELSE '' END || '"' ELSE '' END,
               o.id)
        FROM (SELECT 1) one
        LEFT JOIN board.task p ON p.id = n.parent_id
        CROSS JOIN LATERAL (VALUES (n.assignee, 'task'), (n.created_by, 'task'),
                                   (CASE WHEN n.status IN ('done', 'cancelled') THEN p.assignee END, 'parent'),
                                   (CASE WHEN n.status IN ('done', 'cancelled') THEN p.created_by END, 'parent'),
                                   (CASE WHEN n.status IN ('done', 'cancelled') THEN (SELECT pm FROM board.policy) END, 'task')) r(handle, why)
        JOIN board.agent a ON a.handle = r.handle AND a.kind = 'agent'
        WHERE r.handle <> me
          AND NOT (r.handle = n.assignee AND n.assignee IS DISTINCT FROM o.assignee)
          AND NOT (r.handle = (SELECT pm FROM board.policy) AND n.status IN ('blocked', 'review'))
        ORDER BY r.handle, r.why;  -- 'parent' first: one line per person, with the subtask context
    ELSIF (SELECT kind FROM board.agent WHERE handle = me) = 'human' THEN
        -- a human's note or edit (an approval, an answer, a correction) must reach the agents who own the
        -- task; agents' own notes stay silent (progress reports)
        INSERT INTO board.task_notice (task_id, handle, line)
        SELECT DISTINCT o.id, r.handle, format('[board] task #%s "%s": %s %s%s -- see it with: board task %s',
               o.id, n.title, me,
               CASE WHEN nullif(btrim(task_update.note), '') IS NOT NULL
                    THEN 'noted "' || left(regexp_replace(btrim(task_update.note), '\s+', ' ', 'g'), 200)
                         || CASE WHEN length(btrim(task_update.note)) > 200 THEN '…' ELSE '' END || '"' ELSE 'edited it' END,
               CASE WHEN cardinality(changes) > 0 THEN ' (' || array_to_string(changes, '; ') || ')' ELSE '' END,
               o.id)
        FROM (VALUES (n.assignee), (n.created_by)) r(handle)
        JOIN board.agent a ON a.handle = r.handle AND a.kind = 'agent'
        WHERE NOT (r.handle = n.assignee AND n.assignee IS DISTINCT FROM o.assignee);
    END IF;
    RETURN format('task #%s updated%s', o.id, CASE WHEN cardinality(changes) > 0 THEN ' (' || array_to_string(changes, '; ') || ')' ELSE ': note added' END);
END $$;


--
