-- Name: activity_load(timestamp with time zone, timestamp with time zone, text, text); Type: FUNCTION; Schema: api; Owner: -
--

CREATE OR REPLACE FUNCTION api.activity_load(since timestamp with time zone, until timestamp with time zone DEFAULT now(), bucket text DEFAULT 'day'::text, tz text DEFAULT 'UTC'::text) RETURNS TABLE(handle text, day date, target text, minutes numeric, periods integer)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'board', 'public'
    AS $$
    SELECT p.handle, CASE WHEN bucket = 'total' THEN NULL ELSE (p.minute AT TIME ZONE tz)::date END,
           p.target, round(sum(p.weight), 1), count(DISTINCT p.period)::integer
    FROM board.activity_painted(since, until) p
    WHERE board.require_me() IS NOT NULL
    GROUP BY 1, 2, 3
$$;


--
