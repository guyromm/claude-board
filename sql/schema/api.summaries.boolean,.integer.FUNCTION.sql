-- Name: summaries(boolean, integer); Type: FUNCTION; Schema: api; Owner: -
--

CREATE OR REPLACE FUNCTION api.summaries(pending boolean DEFAULT false, lim integer DEFAULT 30) RETURNS api."text/plain"
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'board', 'public'
    AS $$
    SELECT coalesce(string_agg(line, E'\n' ORDER BY last_id DESC),
                    CASE WHEN pending THEN 'no threads waiting for a summary' ELSE 'no summaries yet' END)
    FROM (
        SELECT t.last_id, CASE WHEN pending
            THEN format('#%s  "%s"  %s msgs, latest #%s %s  (summarized through: %s)', t.thread_id, t.subject,
                        t.size, t.last_id, board.fmt_ts(t.last_at), coalesce('#' || t.summarized_through, 'never'))
            ELSE format('#%s  %s%s%s  "%s"  %s', t.thread_id, upper(t.status),
                        CASE WHEN t.needs_human THEN ' NEEDS-HUMAN' ELSE '' END, CASE WHEN t.stale THEN ' (stale)' ELSE '' END,
                        t.subject, replace(left(t.summary, 160), E'\n', ' '))
            END AS line
        FROM api.threads t
        WHERE board.require_me() IS NOT NULL
          AND CASE WHEN pending THEN t.last_other_id > coalesce(t.summarized_through, 0) ELSE t.status IS NOT NULL END
        ORDER BY t.last_id DESC LIMIT lim
    ) x
$$;


--
