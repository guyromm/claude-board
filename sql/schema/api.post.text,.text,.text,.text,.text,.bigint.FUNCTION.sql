-- Name: post(text, text, text, text, text, bigint); Type: FUNCTION; Schema: api; Owner: -
--

CREATE OR REPLACE FUNCTION api.post(subject text DEFAULT NULL::text, body text DEFAULT NULL::text, recipients text DEFAULT NULL::text, tags text DEFAULT NULL::text, systems text DEFAULT NULL::text, reply_to bigint DEFAULT NULL::bigint) RETURNS json
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'board', 'public'
    AS $$
DECLARE
    me text := board.require_me();
    parent board.message;
    rcpt text[] := board.split_list(post.recipients);
    unknown text[];
    subj text := btrim(coalesce(post.subject, ''));
    m board.message;
    is_all boolean;
    bcast boolean;
BEGIN
    IF coalesce(btrim(post.body), '') = '' THEN RAISE EXCEPTION 'body is required'; END IF;
    IF post.reply_to IS NOT NULL THEN
        SELECT * INTO parent FROM board.message x WHERE x.id = post.reply_to;
        IF NOT FOUND THEN RAISE EXCEPTION 'reply_to #% does not exist', post.reply_to; END IF;
        IF subj = '' THEN subj := CASE WHEN parent.subject ILIKE 're:%' THEN parent.subject ELSE 'Re: ' || parent.subject END; END IF;
        IF cardinality(rcpt) = 0 AND parent.sender <> me THEN rcpt := ARRAY[parent.sender]; END IF;
    END IF;
    IF subj = '' THEN RAISE EXCEPTION 'subject is required'; END IF;
    is_all := 'all' = ANY (rcpt);
    IF is_all THEN
        rcpt := array_remove(rcpt, 'all') || ARRAY(SELECT a.handle FROM board.agent a WHERE a.active AND a.kind = 'agent' ORDER BY a.handle);
    END IF;
    SELECT array_agg(r) INTO unknown FROM unnest(rcpt) r WHERE NOT EXISTS (SELECT 1 FROM board.agent a WHERE a.handle = r);
    IF unknown IS NOT NULL THEN
        RAISE EXCEPTION 'unknown recipient(s): %', array_to_string(unknown, ', ')
            USING HINT = 'list participants with: board agents';
    END IF;
    -- @mentions of real agents in the body
    rcpt := rcpt || ARRAY(
        SELECT DISTINCT rtrim(lower(mm[1]), '._-') FROM regexp_matches(post.body, '(?<![[:alnum:]_@])@([[:alnum:]][[:alnum:]_.-]{0,39})', 'g') mm
        WHERE EXISTS (SELECT 1 FROM board.agent a WHERE a.handle = rtrim(lower(mm[1]), '._-')));

    bcast := is_all OR (SELECT count(DISTINCT r) FROM unnest(rcpt) r JOIN board.agent a ON a.handle = r
                        WHERE a.kind = 'agent' AND r <> me) > (SELECT direct_max_rcpt FROM board.policy);
    PERFORM board.check_budget(me, parent.thread_id, bcast);

    INSERT INTO board.message (sender, subject, body, tags, systems, reply_to, broadcast)
    VALUES (me, subj, post.body, board.split_list(post.tags), board.split_list(post.systems), post.reply_to, bcast)
    RETURNING * INTO m;
    INSERT INTO board.recipient (message_id, handle)
    SELECT DISTINCT m.id, r FROM unnest(rcpt) r WHERE r <> me
    ON CONFLICT DO NOTHING;
    UPDATE board.agent a SET last_seen_at = now() WHERE a.handle = me;
    RETURN json_build_object('id', m.id, 'thread_id', m.thread_id, 'subject', m.subject,
        'recipients', (SELECT coalesce(json_agg(handle ORDER BY handle), '[]') FROM board.recipient WHERE message_id = m.id));
END $$;


--
