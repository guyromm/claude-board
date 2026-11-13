-- Name: review_submit(text, text, text, text, text, text, text, text, text, text, text); Type: FUNCTION; Schema: api; Owner: -
--

CREATE OR REPLACE FUNCTION api.review_submit(repo text, branch text, diff text, title text DEFAULT NULL::text, base text DEFAULT 'master'::text, description text DEFAULT NULL::text, head_sha text DEFAULT NULL::text, base_sha text DEFAULT NULL::text, compare_url text DEFAULT NULL::text, task text DEFAULT NULL::text, note text DEFAULT NULL::text) RETURNS api."text/plain"
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'board', 'public'
    AS $$
DECLARE me text := board.require_me(); r board.review; n integer; tid bigint;
        f integer; a integer; d integer; fresh boolean := false;
BEGIN
    IF coalesce(btrim(review_submit.diff), '') = '' THEN
        RAISE EXCEPTION 'empty diff: nothing differs between % and % (commit and push first)', coalesce(review_submit.base, 'master'), review_submit.branch;
    END IF;
    IF review_submit.task IS NOT NULL AND btrim(review_submit.task) <> '' THEN tid := api.task_id(review_submit.task); END IF;
    SELECT count(*) FILTER (WHERE l ~ '^diff --git '), count(*) FILTER (WHERE l ~ '^\+' AND l !~ '^\+\+\+ '),
           count(*) FILTER (WHERE l ~ '^-' AND l !~ '^--- ')
      INTO f, a, d FROM regexp_split_to_table(review_submit.diff, E'\n') l;
    SELECT * INTO r FROM review x WHERE x.agent = me AND x.repo = btrim(review_submit.repo) AND x.branch = btrim(review_submit.branch)
       AND x.status IN ('open', 'approved', 'changes') FOR UPDATE;
    IF NOT FOUND THEN
        INSERT INTO review (agent, repo, branch, base, title, description, compare_url, task_id)
        VALUES (me, btrim(review_submit.repo), btrim(review_submit.branch), coalesce(nullif(btrim(review_submit.base), ''), 'master'),
                left(coalesce(nullif(btrim(review_submit.title), ''), btrim(review_submit.repo) || ': ' || btrim(review_submit.branch)), 300),
                coalesce(review_submit.description, ''), nullif(btrim(review_submit.compare_url), ''), tid)
        RETURNING * INTO r;
        fresh := true;
    ELSE
        UPDATE review x SET status = 'open', updated_at = now(), decided_by = NULL, decided_at = NULL, decision_note = NULL,
               title = coalesce(nullif(btrim(review_submit.title), ''), x.title),
               description = coalesce(review_submit.description, x.description),
               compare_url = coalesce(nullif(btrim(review_submit.compare_url), ''), x.compare_url),
               task_id = coalesce(tid, x.task_id)
        WHERE x.id = r.id RETURNING * INTO r;
    END IF;
    SELECT coalesce(max(v.rev), 0) + 1 INTO n FROM review_rev v WHERE v.review_id = r.id;
    INSERT INTO review_rev (review_id, rev, head_sha, base_sha, diff, files, adds, dels, note)
    VALUES (r.id, n, nullif(btrim(review_submit.head_sha), ''), nullif(btrim(review_submit.base_sha), ''), review_submit.diff, f, a, d,
            nullif(btrim(review_submit.note), ''));
    RETURN format('review #%s %s (rev %s: %s files, +%s -%s) -- %s', r.id, CASE WHEN fresh THEN 'created' ELSE 'updated' END,
                  n, f, a, d, board.review_url(r.id));
END $$;


--
