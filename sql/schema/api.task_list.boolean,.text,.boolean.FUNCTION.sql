-- Name: task_list(boolean, text, boolean); Type: FUNCTION; Schema: api; Owner: -
--

CREATE OR REPLACE FUNCTION api.task_list(include_closed boolean DEFAULT false, assignee text DEFAULT NULL::text, mine boolean DEFAULT false) RETURNS api."text/plain"
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'board', 'public'
    AS $$
    WITH RECURSIVE pick AS (
        SELECT x.* FROM board.task x
        WHERE (include_closed OR x.status NOT IN ('done', 'cancelled'))
    ), roots AS (
        SELECT p.* FROM pick p
        WHERE CASE WHEN mine OR nullif(task_list.assignee, '') IS NOT NULL
                   THEN p.assignee = CASE WHEN mine THEN board.require_me() ELSE lower(task_list.assignee) END
                   ELSE p.parent_id IS NULL OR p.parent_id NOT IN (SELECT id FROM pick) END
    ), tree AS (
        SELECT r.id, 0 AS depth, ARRAY[r.position, r.id::double precision] AS sort FROM roots r
        UNION ALL
        SELECT c.id, tree.depth + 1, tree.sort || ARRAY[c.position, c.id::double precision]
        FROM pick c JOIN tree ON c.parent_id = tree.id
    )
    SELECT coalesce(string_agg(board.fmt_task(t, tr.depth), E'\n' ORDER BY tr.sort),
                    'no open tasks' || CASE WHEN mine THEN ' assigned to you' ELSE '' END)
    FROM (SELECT DISTINCT ON (id) * FROM tree ORDER BY id, depth) tr JOIN board.task t ON t.id = tr.id
    WHERE board.require_me() IS NOT NULL
$$;


--
