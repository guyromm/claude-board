-- Name: doc(text, integer); Type: FUNCTION; Schema: api; Owner: -
--

CREATE OR REPLACE FUNCTION api.doc(slug text, version integer DEFAULT NULL::integer) RETURNS api."text/plain"
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'board', 'public'
    AS $$
DECLARE d board.doc; v board.doc_version;
BEGIN
    PERFORM board.require_me();
    SELECT * INTO d FROM doc x WHERE x.slug = lower(btrim(doc.slug));
    IF NOT FOUND THEN RAISE EXCEPTION 'no doc "%" (list them with: board docs)', doc.slug; END IF;
    IF doc.version IS NOT NULL AND doc.version <> d.version THEN
        SELECT * INTO v FROM doc_version x WHERE x.doc_id = d.id AND x.version = doc.version;
        IF NOT FOUND THEN RAISE EXCEPTION 'doc "%" has no version % (current: v%)', d.slug, doc.version, d.version; END IF;
        RETURN format(E'== doc:%s v%s (of v%s) "%s" [%s] saved by %s %s\n\n%s', d.slug, v.version, d.version, v.title,
                      v.format, v.saved_by, board.fmt_ts(v.saved_at), v.body);
    END IF;
    RETURN format(E'== doc:%s v%s "%s" [%s] by %s, updated %s by %s\n\n%s', d.slug, d.version, d.title, d.format,
                  d.created_by, board.fmt_ts(d.updated_at), d.updated_by, d.body)
        || coalesce(format(E'\n\n== open comments (reply or resolve at %s/docs/%s#comments)\n',
                           coalesce(nullif(current_setting('board.web_url', true), ''), 'https://board.webgma.co.il'), d.slug) || (
            SELECT string_agg(format(E'#%s %s %s (on v%s) on "%s":\n    %s', c.id, c.author, board.fmt_ts(c.created_at), c.version,
                                     left(c.quote, 160), replace(c.body, E'\n', E'\n    ')), E'\n' ORDER BY c.created_at)
            FROM doc_comment c WHERE c.doc_id = d.id AND c.resolved_at IS NULL), '');
END $$;


--
