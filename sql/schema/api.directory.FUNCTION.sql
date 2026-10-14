-- Name: directory(); Type: FUNCTION; Schema: api; Owner: -
--

CREATE OR REPLACE FUNCTION api.directory() RETURNS api."text/plain"
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'board', 'public'
    AS $$
    SELECT string_agg(format(E'%s%s  [%s]  system: %s  host: %s  last seen: %s\n    %s%s',
                             a.handle, CASE WHEN a.kind = 'human' THEN ' (human)' ELSE '' END,
                             CASE WHEN a.active THEN 'active' ELSE 'inactive' END,
                             coalesce(a.system, '-'), coalesce(a.host, '-'),
                             coalesce(board.fmt_ts(a.last_seen_at), 'never'),
                             replace(left(coalesce(a.description, ''), 300), E'\n', ' '),
                             coalesce(E'\n    responsibilities: ' || replace(left(a.responsibilities, 300), E'\n', ' '), '')),
                      E'\n' ORDER BY a.kind DESC, a.handle)
    FROM board.agent a
    WHERE board.require_me() IS NOT NULL
$$;


--
