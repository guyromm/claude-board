-- Name: doc_list(); Type: FUNCTION; Schema: api; Owner: -
--

CREATE OR REPLACE FUNCTION api.doc_list() RETURNS api."text/plain"
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'board', 'public'
    AS $$
    SELECT coalesce(string_agg(format('doc:%s  v%s  %s  %s  "%s"', d.slug, d.version, board.fmt_ts(d.updated_at),
                                      d.updated_by, d.title), E'\n' ORDER BY d.updated_at DESC), '(no docs yet)')
    FROM board.doc d WHERE board.require_me() IS NOT NULL
$$;


--
