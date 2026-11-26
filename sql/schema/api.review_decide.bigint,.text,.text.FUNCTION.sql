-- Name: review_decide(bigint, text, text); Type: FUNCTION; Schema: api; Owner: -
--

CREATE OR REPLACE FUNCTION api.review_decide(id bigint, decision text, note text DEFAULT NULL::text) RETURNS json
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'board', 'public'
    AS $$
DECLARE me text := board.require_me(); r board.review; dec text := lower(btrim(review_decide.decision)); open_c bigint; msg json;
        v board.review_rev;
BEGIN
    IF NOT board.is_admin() THEN RAISE EXCEPTION 'only an admin decides a review' USING ERRCODE = '42501'; END IF;
    IF dec NOT IN ('approve', 'changes') THEN RAISE EXCEPTION 'decision must be approve or changes, not "%"', review_decide.decision; END IF;
    IF dec = 'changes' AND coalesce(btrim(review_decide.note), '') = ''
       AND NOT EXISTS (SELECT 1 FROM review_comment c WHERE c.review_id = review_decide.id AND c.resolved_at IS NULL) THEN
        RAISE EXCEPTION 'say what to change: add a reason or a comment';
    END IF;
    SELECT * INTO r FROM review x WHERE x.id = review_decide.id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'no review #%', review_decide.id; END IF;
    IF r.status IN ('merged', 'closed') THEN RAISE EXCEPTION 'review #% is already %', r.id, r.status; END IF;
    SELECT * INTO v FROM review_rev x WHERE x.review_id = r.id ORDER BY x.rev DESC LIMIT 1;
    -- a repeated click (guy 11-25: review #401 approved 4x in 30 s) must not notify the agent again:
    -- same decision, already made after the latest revision, no new note -> no-op
    IF ((dec = 'approve' AND r.status = 'approved') OR (dec = 'changes' AND r.status = 'changes'))
       AND r.decided_at IS NOT NULL AND (v.created_at IS NULL OR r.decided_at >= v.created_at)
       AND coalesce(btrim(review_decide.note), '') = '' THEN
        RETURN json_build_object('id', r.id, 'status', r.status, 'message_id', NULL, 'repeat', true);
    END IF;
    UPDATE review x SET status = CASE WHEN dec = 'approve' THEN 'approved' ELSE 'changes' END, decided_by = me, decided_at = now(),
           decision_note = nullif(btrim(review_decide.note), ''), updated_at = now()
    WHERE x.id = r.id RETURNING * INTO r;
    PERFORM board.review_clear_flags(r.id);
    SELECT count(*) INTO open_c FROM review_comment c WHERE c.review_id = r.id AND c.resolved_at IS NULL;
    SELECT * INTO v FROM review_rev x WHERE x.review_id = r.id ORDER BY x.rev DESC LIMIT 1;
    msg := api.post(
        format('Review #%s %s: %s', r.id, CASE WHEN dec = 'approve' THEN 'APPROVED' ELSE 'changes requested' END, left(r.title, 120)),
        CASE WHEN dec = 'approve' THEN
            format(E'%s approved [review #%s](%s) (%s, branch %s -> %s), revision %s = commit %s.%s\n\nMerge EXACTLY the reviewed commit, not the branch tip: `git merge %s` into %s, push %s, then run: board review merged %s --sha <merge commit>. If %s has commits after %s, they were not reviewed: leave them out, or re-submit first (a new revision needs a new approval).%s',
                   me, r.id, board.review_url(r.id), r.repo, r.branch, r.base, v.rev, coalesce(left(v.head_sha, 12), '?'),
                   coalesce(E'\n\n' || nullif(btrim(review_decide.note), ''), ''),
                   coalesce(v.head_sha, r.branch), r.base, r.base, r.id, r.branch, coalesce(left(v.head_sha, 12), 'the reviewed commit'),
                   CASE WHEN open_c > 0 THEN format(E'\n(%s open comment(s) on it: read them first; apply small ones before merging.)', open_c) ELSE '' END)
        ELSE
            format(E'%s requested changes on [review #%s](%s) (%s, branch %s).%s\n\n%s open comment(s): see them with board review %s. Fix on the branch, push, and re-submit: board review submit ... (same branch = a new revision of this review).',
                   me, r.id, board.review_url(r.id), r.repo, r.branch,
                   coalesce(E'\n\nReason: ' || nullif(btrim(review_decide.note), ''), ''), open_c, r.id)
        END,
        r.agent, 'review');
    RETURN json_build_object('id', r.id, 'status', r.status, 'message_id', msg->>'id');
END $$;


--
