-- Name: task_project(bigint); Type: FUNCTION; Schema: board; Owner: -
--

CREATE OR REPLACE FUNCTION board.task_project(id bigint) RETURNS bigint
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'board', 'public'
    AS $$
    WITH RECURSIVE up AS (
        SELECT t.id, t.parent_id, t.kind, 0 AS d FROM board.task t WHERE t.id = task_project.id
        UNION ALL
        SELECT p.id, p.parent_id, p.kind, up.d + 1 FROM board.task p JOIN up ON p.id = up.parent_id WHERE up.kind <> 'project'
    )
    SELECT up.id FROM up WHERE up.kind = 'project' ORDER BY d LIMIT 1
$$;


--
