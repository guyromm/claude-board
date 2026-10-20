-- Name: task_human_answered(bigint); Type: FUNCTION; Schema: board; Owner: -
--

CREATE OR REPLACE FUNCTION board.task_human_answered(t bigint) RETURNS boolean
    LANGUAGE sql STABLE
    AS $$
    SELECT EXISTS (
        SELECT 1 FROM board.task_note n JOIN board.agent a ON a.handle = n.author AND a.kind = 'human'
        WHERE n.task_id = t AND n.id > coalesce((SELECT max(e.id) FROM board.task_note e
                                                  WHERE e.task_id = t AND e.change ~ 'escalated to the human'), 0))
$$;


--
