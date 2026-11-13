-- Name: reviews; Type: VIEW; Schema: api; Owner: -
--

CREATE OR REPLACE VIEW api.reviews AS
 SELECT r.id,
    r.agent,
    r.repo,
    r.branch,
    r.base,
    r.title,
    r.description,
    r.compare_url,
    r.task_id,
    t.path AS task_path,
    r.remote,
    COALESCE(board.remote_repo(r.remote), r.repo) AS repo_name,
    r.status,
    r.decided_by,
    r.decided_at,
    r.decision_note,
    r.merged_sha,
    r.created_at,
    r.updated_at,
    v.rev,
    v.head_sha,
    v.files,
    v.adds,
    v.dels,
    v.created_at AS rev_at,
    ( SELECT count(*) AS count
           FROM board.review_comment c
          WHERE ((c.review_id = r.id) AND (c.resolved_at IS NULL))) AS open_comments
   FROM ((board.review r
     LEFT JOIN board.task t ON ((t.id = r.task_id)))
     LEFT JOIN LATERAL ( SELECT x.review_id,
            x.rev,
            x.head_sha,
            x.base_sha,
            x.diff,
            x.files,
            x.adds,
            x.dels,
            x.note,
            x.created_at
           FROM board.review_rev x
          WHERE (x.review_id = r.id)
          ORDER BY x.rev DESC
         LIMIT 1) v ON (true));


--
