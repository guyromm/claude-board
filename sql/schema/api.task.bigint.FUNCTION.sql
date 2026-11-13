-- Name: task(bigint); Type: FUNCTION; Schema: api; Owner: -
--

CREATE OR REPLACE FUNCTION api.task(id bigint) RETURNS api."text/plain"
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'board', 'public'
    AS $$
DECLARE t board.task; path text; subs text; ths text; log text;
BEGIN
    PERFORM board.require_me();
    SELECT * INTO t FROM board.task x WHERE x.id = task.id;
    IF NOT FOUND THEN RETURN format('task #%s not found', task.id); END IF;
    WITH RECURSIVE up AS (SELECT x.id, x.parent_id, x.title, 0 AS d FROM board.task x WHERE x.id = t.parent_id
                          UNION ALL SELECT p.id, p.parent_id, p.title, up.d + 1 FROM board.task p JOIN up ON p.id = up.parent_id)
    SELECT string_agg(format('%s %s', board.task_ref(up.id), up.title), ' > ' ORDER BY up.d DESC) INTO path FROM up;
    SELECT string_agg(board.fmt_task(c, 1), E'\n' ORDER BY c.status = 'done', c.position, c.id) INTO subs
    FROM board.task c WHERE c.parent_id = t.id AND c.status <> 'cancelled';
    SELECT string_agg(format('  #%s "%s"  %s%s', x.thread_id, x.subject, upper(coalesce(x.status, 'unsummarized')),
                             coalesce(': ' || replace(left(x.summary, 200), E'\n', ' '), '')), E'\n' ORDER BY x.thread_id) INTO ths
    FROM api.task_threads x WHERE x.task_id = t.id;
    SELECT string_agg(format('  %s %s: %s', board.fmt_ts(n.created_at), n.author,
                             concat_ws(' | ', '[' || n.change || ']', nullif(n.body, ''))), E'\n' ORDER BY n.id) INTO log
    -- the latest 15, plus the latest 10 by anyone but the PM: its own check-in notes must not push the
    -- owners' reports (and the human's answers) out of view
    FROM board.task_note n
    WHERE n.id IN (SELECT x.id FROM board.task_note x WHERE x.task_id = t.id ORDER BY x.id DESC LIMIT 15)
       OR n.id IN (SELECT x.id FROM board.task_note x WHERE x.task_id = t.id AND x.author <> (SELECT pm FROM board.policy)
                   ORDER BY x.id DESC LIMIT 10);
    RETURN concat_ws(E'\n',
        board.fmt_task(t),
        CASE WHEN path IS NOT NULL THEN 'Under:    ' || path END,
        format('Created:  %s by %s · check-in every %s · last activity %s ago', board.fmt_ts(t.created_at), t.created_by,
               t.check_every, board.fmt_age(now() - t.activity_at)),
        CASE WHEN t.description <> '' THEN E'\n' || t.description END,
        E'\nSubtasks:', coalesce(subs, '  (none)'),
        E'\nThreads:', coalesce(ths, '  (none)'),
        E'\nLog (latest 15, plus the 10 latest not by the PM):', coalesce(log, '  (empty)'),
        E'\n-- note: board task note ' || t.id || ' -m "..." | status: board task update ' || t.id
            || ' --status todo|doing|blocked|review|done | subtask: board task new --parent ' || t.id || ' --title "..." --assignee H');
END $$;


--
