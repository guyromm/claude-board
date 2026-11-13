-- Name: review_text(bigint, boolean, boolean); Type: FUNCTION; Schema: api; Owner: -
--

CREATE OR REPLACE FUNCTION api.review_text(id bigint DEFAULT NULL::bigint, mine boolean DEFAULT true, include_closed boolean DEFAULT false) RETURNS api."text/plain"
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'board', 'public'
    AS $$
DECLARE me text := board.require_me(); r api.reviews; out text;
BEGIN
    IF review_text.id IS NULL THEN
        RETURN coalesce((SELECT string_agg(format('#%s [%s] %s  %s:%s -> %s  rev %s (+%s -%s), %s open comment(s)  %s',
                        x.id, x.status, x.agent, x.repo, x.branch, x.base, x.rev, x.adds, x.dels, x.open_comments, board.review_url(x.id)),
                        E'\n' ORDER BY x.updated_at DESC)
            FROM api.reviews x WHERE (NOT mine OR x.agent = me) AND (include_closed OR x.status NOT IN ('merged', 'closed'))),
            '(no reviews)');
    END IF;
    SELECT * INTO r FROM api.reviews x WHERE x.id = review_text.id;
    IF NOT FOUND THEN RAISE EXCEPTION 'no review #%', review_text.id; END IF;
    out := format(E'== review #%s [%s] "%s" by %s\n%s branch %s -> %s, rev %s (%s, +%s -%s) -- %s%s%s',
                  r.id, r.status, r.title, r.agent, r.repo, r.branch, r.base, r.rev, coalesce(left(r.head_sha, 12), '?'), r.adds, r.dels,
                  board.review_url(r.id),
                  CASE WHEN r.decided_at IS NOT NULL THEN format(E'\ndecision: %s by %s %s', r.status, r.decided_by, board.fmt_ts(r.decided_at)) ELSE '' END,
                  coalesce(E'\nnote: ' || r.decision_note, ''));
    RETURN out || coalesce(E'\n\n== open comments\n' || (
        SELECT string_agg(format(E'#%s %s %s (rev %s)%s%s:\n    %s', c.id, c.author, board.fmt_ts(c.created_at), c.rev,
                                 CASE WHEN c.path <> '' THEN ' ' || c.path || coalesce(format(' %s:%s', c.side, c.line), '') ELSE '' END,
                                 CASE WHEN c.quote <> '' THEN format(' on "%s"', left(replace(c.quote, E'\n', ' '), 160)) ELSE '' END,
                                 replace(c.body, E'\n', E'\n    ')), E'\n' ORDER BY c.created_at)
        FROM review_comment c WHERE c.review_id = r.id AND c.resolved_at IS NULL), '');
END $$;


--
