-- Name: task_create(text, text, text, bigint, text, text, text); Type: FUNCTION; Schema: api; Owner: -
--

CREATE OR REPLACE FUNCTION api.task_create(title text, description text DEFAULT NULL::text, assignee text DEFAULT NULL::text, parent bigint DEFAULT NULL::bigint, status text DEFAULT 'todo'::text, check_every text DEFAULT NULL::text, due text DEFAULT NULL::text) RETURNS api."text/plain"
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'board', 'public'
    AS $$
DECLARE me text := board.require_me(); t board.task; who text := nullif(lower(btrim(task_create.assignee, ' @')), '');
BEGIN
    IF who IS NOT NULL AND NOT EXISTS (SELECT 1 FROM board.agent a WHERE a.handle = who) THEN
        RAISE EXCEPTION 'unknown assignee "%"', who USING HINT = 'list participants with: board agents';
    END IF;
    IF parent IS NOT NULL AND NOT EXISTS (SELECT 1 FROM board.task x WHERE x.id = parent) THEN
        RAISE EXCEPTION 'parent task #% not found', parent;
    END IF;
    INSERT INTO board.task (parent_id, title, description, status, assignee, created_by, check_every, due_at)
    VALUES (parent, btrim(task_create.title), coalesce(task_create.description, ''), board.task_status(coalesce(task_create.status, 'todo')),
            who, me, coalesce(board.task_interval(nullif(task_create.check_every, '')), interval '1 day'),
            nullif(due, '')::timestamptz)
    RETURNING * INTO t;
    INSERT INTO board.task_note (task_id, author, body, change)
    VALUES (t.id, me, '', format('created%s', coalesce(', assigned to ' || who, '')));
    RETURN format('task #%s created: %s', t.id, board.fmt_task(t));
END $$;


--
