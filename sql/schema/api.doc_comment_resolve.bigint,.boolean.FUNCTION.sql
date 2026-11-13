-- Name: doc_comment_resolve(bigint, boolean); Type: FUNCTION; Schema: api; Owner: -
--

CREATE OR REPLACE FUNCTION api.doc_comment_resolve(id bigint, resolved boolean DEFAULT true) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'board', 'public'
    AS $$
DECLARE me text := board.require_me(); c board.doc_comment;
BEGIN
    SELECT * INTO c FROM doc_comment x WHERE x.id = doc_comment_resolve.id;
    IF NOT FOUND THEN RAISE EXCEPTION 'no comment #%', doc_comment_resolve.id; END IF;
    IF me <> c.author AND me <> (SELECT d.created_by FROM doc d WHERE d.id = c.doc_id)
       AND NOT (me = (SELECT pm FROM policy) OR (SELECT is_admin FROM agent WHERE handle = me)) THEN
        RAISE EXCEPTION 'only the commenter, the doc author or an admin can resolve comment #%', c.id USING ERRCODE = '42501';
    END IF;
    UPDATE doc_comment x SET resolved_at = CASE WHEN resolved THEN now() END, resolved_by = CASE WHEN resolved THEN me END
    WHERE x.id = c.id;
END $$;


--
