-- Name: activity_push(text); Type: FUNCTION; Schema: api; Owner: -
--

CREATE OR REPLACE FUNCTION api.activity_push(data text) RETURNS api."text/plain"
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'board', 'public'
    AS $_$
DECLARE me text := board.require_me(); n integer;
BEGIN
    -- v16 read every transcript of the unix user: agents sharing one (caladan) reported each other's work. v17 reads
    -- only its own session's directory, from scratch (a new state file); v16's pushes are dropped.
    IF coalesce((SELECT a.watcher_version FROM board.agent a WHERE a.handle = me), 0) < 17 THEN
        RETURN 'ok 0 minutes (watcher older than v17: ignored)';
    END IF;
    WITH l AS (
        SELECT split_part(x, E'\t', 1) AS e, split_part(x, E'\t', 2) AS c, split_part(x, E'\t', 3) AS r
        FROM regexp_split_to_table(coalesce(data, ''), E'\n') x
    ), p AS (
        SELECT date_trunc('minute', to_timestamp(e::bigint)) AS minute,
               CASE WHEN c ~ '^\d{1,6}$' THEN c::integer ELSE 0 END AS c,
               ARRAY(SELECT DISTINCT left(t, 40) FROM regexp_split_to_table(r, ' ') t
                     WHERE t ~ '^([tpmn]:\d[\d/]*|u:[A-Za-z0-9_.-]{1,30})$' LIMIT 40) AS refs
        FROM l WHERE e ~ '^\d{9,11}$'
    ), f AS (
        SELECT p.minute, r FROM p, unnest(p.refs) r
    ), g AS (
        SELECT p.minute, sum(p.c)::integer AS c,
               coalesce((SELECT array_agg(DISTINCT f.r) FROM f WHERE f.minute = p.minute), '{}') AS refs
        FROM p GROUP BY p.minute
    ), ins AS (
        INSERT INTO board.activity_minute AS a (handle, minute, lines, refs, targets)
        SELECT me, g.minute, g.c, g.refs,
               ARRAY(SELECT DISTINCT x FROM unnest(g.refs) r, board.activity_target(r, g.minute) x WHERE x IS NOT NULL)
        FROM g WHERE g.minute > now() - interval '400 days' AND g.minute < now() + interval '10 minutes'
        ON CONFLICT (handle, minute) DO UPDATE SET
            lines = a.lines + EXCLUDED.lines,
            refs = ARRAY(SELECT DISTINCT u FROM unnest(a.refs || EXCLUDED.refs) u),
            targets = ARRAY(SELECT DISTINCT u FROM unnest(a.targets || EXCLUDED.targets) u),
            pushed_at = now()
        RETURNING 1
    )
    SELECT count(*) INTO n FROM ins;
    RETURN format('ok %s minutes', n);
END $_$;


--
