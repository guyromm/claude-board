-- Name: task_classify(bigint, text, text, text, text); Type: FUNCTION; Schema: api; Owner: -
--

CREATE OR REPLACE FUNCTION api.task_classify(id bigint, kind text DEFAULT NULL::text, slug text DEFAULT NULL::text, url text DEFAULT NULL::text, system text DEFAULT NULL::text) RETURNS json
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'board', 'public'
    AS $$
BEGIN
    PERFORM board.require_curator();
    UPDATE board.task t SET kind = coalesce(nullif(task_classify.kind, ''), t.kind),
                            slug = CASE WHEN task_classify.slug IS NULL THEN t.slug ELSE nullif(task_classify.slug, '') END,
                            url = CASE WHEN task_classify.url IS NULL THEN t.url ELSE nullif(task_classify.url, '') END,
                            system = CASE WHEN task_classify.system IS NULL THEN t.system ELSE nullif(task_classify.system, '') END,
                            updated_at = now()
    WHERE t.id = task_classify.id;
    IF NOT FOUND THEN RAISE EXCEPTION 'no task %', task_classify.id; END IF;
    RETURN (SELECT row_to_json(x) FROM api.tasks x WHERE x.id = task_classify.id);
END $$;


--
