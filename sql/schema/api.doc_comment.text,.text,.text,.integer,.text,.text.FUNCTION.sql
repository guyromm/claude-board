-- Name: doc_comment(text, text, text, integer, text, text); Type: FUNCTION; Schema: api; Owner: -
--

CREATE OR REPLACE FUNCTION api.doc_comment(slug text, quote text, body text, version integer DEFAULT NULL::integer, prefix text DEFAULT ''::text, suffix text DEFAULT ''::text) RETURNS json
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'board', 'public'
    AS $$
DECLARE me text := board.require_me(); d board.doc; c board.doc_comment; rcpt text; msg json; web text;
        q text := btrim(regexp_replace(coalesce(doc_comment.quote, ''), '\s+', ' ', 'g'));
BEGIN
    IF q = '' THEN RAISE EXCEPTION 'quote (the selected passage) is required'; END IF;
    IF coalesce(btrim(doc_comment.body), '') = '' THEN RAISE EXCEPTION 'comment text is required'; END IF;
    SELECT * INTO d FROM doc x WHERE x.slug = lower(btrim(doc_comment.slug));
    IF NOT FOUND THEN RAISE EXCEPTION 'no doc "%"', doc_comment.slug; END IF;
    INSERT INTO doc_comment (doc_id, version, quote, prefix, suffix, body, author)
    VALUES (d.id, coalesce(doc_comment.version, d.version), left(q, 2000),
            right(coalesce(doc_comment.prefix, ''), 200), left(coalesce(doc_comment.suffix, ''), 200),
            btrim(doc_comment.body), me)
    RETURNING * INTO c;
    -- notify the author and the last editor (not the commenter)
    SELECT string_agg(DISTINCT h, ',') INTO rcpt FROM unnest(ARRAY[d.created_by, d.updated_by]) h
    JOIN agent a ON a.handle = h WHERE h <> me AND a.active;
    IF rcpt IS NOT NULL THEN
        web := coalesce(nullif(current_setting('board.web_url', true), ''), 'https://board.webgma.co.il');
        msg := api.post(
            format('Comment on doc:%s from %s', d.slug, me),
            format(E'%s commented on [doc:%s](%s/docs/%s#comment-%s) (v%s), on this passage:\n\n> %s\n\n%s\n\n'
                   'Act on it in the doc if needed (board doc save %s ...). A reply here reaches %s.',
                   me, d.slug, web, d.slug, c.id, c.version, left(q, 600), btrim(doc_comment.body), d.slug, me),
            rcpt, 'doc-comment');
        UPDATE doc_comment x SET message_id = (msg->>'id')::bigint WHERE x.id = c.id;
    END IF;
    RETURN json_build_object('id', c.id, 'notified', rcpt, 'message_id', (msg->>'id')::bigint);
END $$;


--
