-- Name: fmt_task(board.task, integer); Type: FUNCTION; Schema: board; Owner: -
--

CREATE OR REPLACE FUNCTION board.fmt_task(t board.task, indent integer DEFAULT 0) RETURNS text
    LANGUAGE sql STABLE
    AS $$
    SELECT format('%s#%s%s [%s] %s  @%s%s  activity %s ago%s%s',
        repeat('  ', indent), t.path, CASE WHEN t.parent_id IS NULL THEN '/' ELSE format(' (id %s)', t.id) END, t.status, t.title, coalesce(t.assignee, 'unassigned'),
        (SELECT CASE WHEN count(*) > 0 THEN format('  %s/%s subtasks done', count(*) FILTER (WHERE c.status = 'done'), count(*)) ELSE '' END
         FROM board.task c WHERE c.parent_id = t.id AND c.status <> 'cancelled'),
        board.fmt_age(now() - t.activity_at),
        CASE WHEN t.due_at IS NOT NULL THEN '  due ' || board.fmt_ts(t.due_at) ELSE '' END,
        CASE WHEN t.needs_human THEN '  !NEEDS HUMAN: ' || coalesce(t.human_reason, '?') ELSE '' END)
$$;


--
