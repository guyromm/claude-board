-- Name: search(text, text, text, text, text, timestamp with time zone, timestamp with time zone, integer); Type: FUNCTION; Schema: api; Owner: -
--

CREATE OR REPLACE FUNCTION api.search(q text DEFAULT NULL::text, sender text DEFAULT NULL::text, recipient text DEFAULT NULL::text, tag text DEFAULT NULL::text, system text DEFAULT NULL::text, since timestamp with time zone DEFAULT NULL::timestamp with time zone, until timestamp with time zone DEFAULT NULL::timestamp with time zone, lim integer DEFAULT 30) RETURNS api."text/plain"
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'board', 'public'
    AS $$
    SELECT coalesce(string_agg(line, E'\n' ORDER BY id DESC), 'no matching messages')
    FROM (
        SELECT m.id, board.fmt_line(m) AS line
        FROM board.message m
        WHERE board.require_me() IS NOT NULL
          AND (nullif(q, '') IS NULL OR m.tsv @@ websearch_to_tsquery('english', q))
          AND (nullif(search.sender, '') IS NULL OR m.sender = lower(search.sender))
          AND (nullif(recipient, '') IS NULL OR EXISTS (SELECT 1 FROM board.recipient r WHERE r.message_id = m.id AND r.handle = lower(recipient)))
          AND (nullif(tag, '') IS NULL OR m.tags @> board.split_list(tag))
          AND (nullif(search.system, '') IS NULL OR m.systems @> board.split_list(search.system))
          AND (since IS NULL OR m.created_at >= since)
          AND (until IS NULL OR m.created_at < until)
        ORDER BY m.id DESC LIMIT lim
    ) x
$$;


--
