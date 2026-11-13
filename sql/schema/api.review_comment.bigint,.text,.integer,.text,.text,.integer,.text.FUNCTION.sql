-- Name: review_comment(bigint, text, integer, text, text, integer, text); Type: FUNCTION; Schema: api; Owner: -
--

CREATE OR REPLACE FUNCTION api.review_comment(id bigint, body text, rev integer DEFAULT NULL::integer, path text DEFAULT ''::text, side text DEFAULT 'new'::text, line integer DEFAULT NULL::integer, quote text DEFAULT ''::text) RETURNS json
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'board', 'public'
    AS $$
DECLARE me text := board.require_me(); r board.review; c board.review_comment; rcpt text; msg json; q text;
BEGIN
    IF coalesce(btrim(review_comment.body), '') = '' THEN RAISE EXCEPTION 'comment text is required'; END IF;
    SELECT * INTO r FROM review x WHERE x.id = review_comment.id;
    IF NOT FOUND THEN RAISE EXCEPTION 'no review #%', review_comment.id; END IF;
    q := left(btrim(coalesce(review_comment.quote, '')), 4000);
    INSERT INTO review_comment (review_id, rev, path, side, line, quote, body, author)
    VALUES (r.id, coalesce(review_comment.rev, (SELECT max(v.rev) FROM review_rev v WHERE v.review_id = r.id)),
            coalesce(review_comment.path, ''), coalesce(nullif(review_comment.side, ''), 'new'), review_comment.line, q,
            btrim(review_comment.body), me)
    RETURNING * INTO c;
    IF me <> r.agent THEN rcpt := r.agent;
    ELSE rcpt := r.decided_by;  -- the agent's own replies reach a decider only; guy sees the rest in the UI/digest
    END IF;
    IF rcpt IS NOT NULL THEN
        msg := api.post(format('Review #%s comment from %s: %s', r.id, me, left(r.title, 120)),
            format(E'%s commented on [review #%s](%s#c%s) (%s %s, rev %s)%s:\n\n%s%s\n\n%s',
                   me, r.id, board.review_url(r.id), c.id, r.repo, r.branch, c.rev,
                   CASE WHEN c.path <> '' THEN format(' at `%s`%s', c.path, coalesce(format(' %s line %s', c.side, c.line), '')) ELSE '' END,
                   CASE WHEN q <> '' THEN '> ' || replace(left(q, 800), E'\n', E'\n> ') || E'\n\n' ELSE '' END,
                   btrim(review_comment.body),
                   CASE WHEN me <> r.agent THEN 'Address it on the branch, push, and re-submit (board review submit ...). A reply here reaches ' || me || '.' ELSE '' END),
            rcpt, 'review');
        UPDATE review_comment x SET message_id = (msg->>'id')::bigint WHERE x.id = c.id;
    END IF;
    UPDATE review x SET updated_at = now() WHERE x.id = r.id;
    RETURN json_build_object('id', c.id, 'notified', rcpt);
END $$;


--
