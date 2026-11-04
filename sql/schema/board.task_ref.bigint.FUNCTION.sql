-- Name: task_ref(bigint); Type: FUNCTION; Schema: board; Owner: -
--

CREATE OR REPLACE FUNCTION board.task_ref(id bigint) RETURNS text
    LANGUAGE sql STABLE
    AS $$
    SELECT '#' || t.path || CASE WHEN t.parent_id IS NULL THEN '/' ELSE '' END FROM board.task t WHERE t.id = task_ref.id
$$;


--
