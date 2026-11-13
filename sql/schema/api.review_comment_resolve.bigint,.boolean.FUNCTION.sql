-- Name: review_comment_resolve(bigint, boolean); Type: FUNCTION; Schema: api; Owner: -
--

CREATE OR REPLACE FUNCTION api.review_comment_resolve(id bigint, resolved boolean DEFAULT true) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'board', 'public'
    AS $$
DECLARE me text := board.require_me(); c board.review_comment; r board.review;
BEGIN
    SELECT * INTO c FROM review_comment x WHERE x.id = review_comment_resolve.id;
    IF NOT FOUND THEN RAISE EXCEPTION 'no review comment #%', review_comment_resolve.id; END IF;
    SELECT * INTO r FROM review x WHERE x.id = c.review_id;
    IF me NOT IN (c.author, r.agent) AND NOT board.is_admin() THEN
        RAISE EXCEPTION 'only the commenter, the review''s agent or an admin can resolve comment #%', c.id USING ERRCODE = '42501';
    END IF;
    UPDATE review_comment x SET resolved_at = CASE WHEN resolved THEN now() END, resolved_by = CASE WHEN resolved THEN me END
    WHERE x.id = c.id;
END $$;


--
