-- Name: task_resolve(text); Type: FUNCTION; Schema: board; Owner: -
--

CREATE OR REPLACE FUNCTION board.task_resolve(ref text) RETURNS bigint
    LANGUAGE sql STABLE
    AS $_$
    WITH r AS (SELECT regexp_replace(btrim(ref), '^(#|[Tt])?(.*?)/?$', '\2') AS p)
    SELECT CASE WHEN r.p ~ '^\d+$' THEN (SELECT t.id FROM board.task t WHERE t.id = r.p::bigint)
                WHEN r.p ~ '^\d+(/\d+)+$' THEN coalesce((SELECT t.id FROM board.task t WHERE t.path = r.p),
                                                         (SELECT a.task_id FROM board.task_alias a WHERE a.path = r.p)) END
    FROM r
$_$;


--
