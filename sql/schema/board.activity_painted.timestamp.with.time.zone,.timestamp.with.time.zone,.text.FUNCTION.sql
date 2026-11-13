-- Name: activity_painted(timestamp with time zone, timestamp with time zone, text); Type: FUNCTION; Schema: board; Owner: -
--

CREATE OR REPLACE FUNCTION board.activity_painted(since timestamp with time zone, until timestamp with time zone, who text DEFAULT NULL::text) RETURNS TABLE(handle text, period timestamp with time zone, minute timestamp with time zone, lines integer, target text, weight numeric)
    LANGUAGE sql STABLE
    AS $$
    WITH m AS (
        SELECT a.handle, a.minute, a.lines, a.targets,
               EXISTS (SELECT 1 FROM unnest(a.refs) r WHERE r LIKE 'u:%') AS prompt
        FROM board.activity_minute a
        WHERE a.minute >= since AND a.minute < until AND (who IS NULL OR a.handle = who)
    ), isl AS (   -- consecutive minutes share grp (gaps and islands)
        SELECT m.*, m.minute - (row_number() OVER (PARTITION BY m.handle ORDER BY m.minute)) * interval '1 minute' AS grp FROM m
    ), sg AS (    -- a new prompt (a human's "[from X]" or a watcher line) starts a new segment of the period
        SELECT isl.*, count(*) FILTER (WHERE isl.prompt) OVER (PARTITION BY isl.handle, isl.grp ORDER BY isl.minute) AS seg FROM isl
    ), mk AS (    -- c: how many mentioning minutes so far in the segment
        SELECT sg.*, count(*) FILTER (WHERE cardinality(sg.targets) > 0)
                     OVER (PARTITION BY sg.handle, sg.grp, sg.seg ORDER BY sg.minute) AS c FROM sg
    ), tg AS (
        SELECT mk.handle, mk.grp, mk.seg, mk.c, mk.targets FROM mk WHERE cardinality(mk.targets) > 0
    ), att AS (
        SELECT mk.handle, mk.grp, mk.minute, mk.lines, coalesce(tg.targets, '{}') AS targets
        FROM mk LEFT JOIN tg ON tg.handle = mk.handle AND tg.grp = mk.grp AND tg.seg = mk.seg AND tg.c = greatest(mk.c, 1)
    )
    SELECT att.handle, min(att.minute) OVER (PARTITION BY att.handle, att.grp), att.minute, att.lines, t,
           round(1.0 / greatest(cardinality(att.targets), 1), 4)
    FROM att, unnest(CASE WHEN cardinality(att.targets) = 0 THEN '{""}'::text[] ELSE att.targets END) t
$$;


--
