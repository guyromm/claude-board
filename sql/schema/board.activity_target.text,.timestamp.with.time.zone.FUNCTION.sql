-- Name: activity_target(text, timestamp with time zone); Type: FUNCTION; Schema: board; Owner: -
--

CREATE OR REPLACE FUNCTION board.activity_target(ref text, at timestamp with time zone) RETURNS text
    LANGUAGE plpgsql STABLE
    AS $_$
DECLARE k text := split_part(ref, ':', 1); v text := split_part(ref, ':', 2); n bigint; th bigint; tk bigint;
BEGIN
    IF k = 't' AND v ~ '^\d{1,9}$' THEN
        RETURN (SELECT 't' || t.id FROM board.task t WHERE t.id = v::bigint);
    ELSIF k = 'p' AND v ~ '^\d{1,9}(/\d{1,9})*$' THEN
        RETURN 't' || board.task_resolve(v);
    ELSIF k IN ('m', 'n') AND v ~ '^\d{1,9}$' THEN
        n := v::bigint;
        IF k = 'n' AND n < 10 THEN RETURN NULL; END IF;      -- "#1", "#2": list items, not board objects
        SELECT coalesce(m.thread_id, m.id) INTO th FROM board.message m
        WHERE m.id = n AND (k = 'm' OR m.created_at > at - interval '14 days');
        IF th IS NULL THEN
            RETURN CASE WHEN k = 'n' THEN (SELECT 't' || t.id FROM board.task t WHERE t.path = v) END;
        END IF;
        SELECT x.task_id INTO tk FROM board.task_thread x JOIN board.task t ON t.id = x.task_id
        WHERE x.thread_id = th ORDER BY length(t.path) DESC, x.linked_at DESC LIMIT 1;
        RETURN coalesce('t' || tk, 'h' || th);
    END IF;
    RETURN NULL;
END $_$;


--
