-- Name: task_can_edit(bigint, text); Type: FUNCTION; Schema: board; Owner: -
--

CREATE OR REPLACE FUNCTION board.task_can_edit(t bigint, me text) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'board', 'public'
    AS $$
    WITH RECURSIVE up AS (
        SELECT id, parent_id, assignee, created_by FROM board.task WHERE id = t
        UNION ALL
        SELECT p.id, p.parent_id, p.assignee, p.created_by FROM board.task p JOIN up ON p.id = up.parent_id
    )
    SELECT me = (SELECT pm FROM board.policy)
        OR EXISTS (SELECT 1 FROM board.agent a WHERE a.handle = me AND a.is_admin)
        OR EXISTS (SELECT 1 FROM up WHERE up.assignee = me)
        OR (SELECT created_by FROM board.task WHERE id = t) = me
$$;


--
