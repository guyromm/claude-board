-- Name: activity_periods(timestamp with time zone, timestamp with time zone, text); Type: FUNCTION; Schema: api; Owner: -
--

CREATE OR REPLACE FUNCTION api.activity_periods(since timestamp with time zone, until timestamp with time zone DEFAULT now(), who text DEFAULT NULL::text) RETURNS TABLE(handle text, started timestamp with time zone, ended timestamp with time zone, minutes integer, lines integer, targets jsonb, drivers text[])
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'board', 'public'
    AS $$
    WITH p AS (SELECT * FROM board.activity_painted(since, until, nullif(who, '')) WHERE board.require_me() IS NOT NULL),
    per AS (
        SELECT p.handle, p.period, max(p.minute) + interval '1 minute' AS ended,
               count(DISTINCT p.minute)::integer AS minutes
        FROM p GROUP BY 1, 2
    ), ln AS (
        SELECT x.handle, x.period, sum(x.lines)::integer AS lines
        FROM (SELECT DISTINCT p.handle, p.period, p.minute, p.lines FROM p) x GROUP BY 1, 2
    ), tg AS (
        SELECT p.handle, p.period, jsonb_agg(jsonb_build_object('target', p.target, 'minutes', round(p.m, 1)) ORDER BY p.m DESC) AS targets
        FROM (SELECT p.handle, p.period, p.target, sum(p.weight) AS m FROM p GROUP BY 1, 2, 3) p GROUP BY 1, 2
    )
    SELECT per.handle, per.period, per.ended, per.minutes, ln.lines, tg.targets,
           ARRAY(SELECT DISTINCT substr(r, 3) FROM board.activity_minute a, unnest(a.refs) r
                 WHERE a.handle = per.handle AND a.minute >= per.period AND a.minute < per.ended AND r LIKE 'u:%') AS drivers
    FROM per JOIN ln USING (handle, period) JOIN tg USING (handle, period)
    ORDER BY per.period DESC
$$;


--
