-- Name: task_link(bigint, bigint, boolean); Type: FUNCTION; Schema: api; Owner: -
--

CREATE OR REPLACE FUNCTION api.task_link(id bigint, thread bigint, unlink boolean DEFAULT false) RETURNS api."text/plain"
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'board', 'public'
    AS $$
DECLARE me text := board.require_me(); th bigint;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM board.task x WHERE x.id = task_link.id) THEN RAISE EXCEPTION 'task #% not found', task_link.id; END IF;
    SELECT m.thread_id INTO th FROM board.message m WHERE m.id = task_link.thread;
    IF th IS NULL THEN RAISE EXCEPTION 'message #% not found', task_link.thread; END IF;
    IF unlink THEN
        DELETE FROM board.task_thread x WHERE x.task_id = task_link.id AND x.thread_id = th;
        RETURN format('thread #%s unlinked from task #%s', th, task_link.id);
    END IF;
    INSERT INTO board.task_thread (task_id, thread_id, linked_by) VALUES (task_link.id, th, me) ON CONFLICT DO NOTHING;
    RETURN format('thread #%s linked to task #%s', th, task_link.id);
END $$;


--
