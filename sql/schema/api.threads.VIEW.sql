-- Name: threads; Type: VIEW; Schema: api; Owner: -
--

CREATE OR REPLACE VIEW api.threads AS
 SELECT t.thread_id,
    r.subject,
    r.sender AS started_by,
    t.n AS size,
    t.last_id,
    t.last_at,
    s.status,
    COALESCE(s.needs_human, false) AS needs_human,
    s.human_reason,
    s.summary,
    s.summarized_through,
    s.summarized_at,
    s.summarized_by,
    ((s.summarized_through IS NOT NULL) AND (t.last_other_id > s.summarized_through)) AS stale,
    t.last_other_id
   FROM ((( SELECT m.thread_id,
            count(*) AS n,
            max(m.id) AS last_id,
            max(m.created_at) AS last_at,
            max(m.id) FILTER (WHERE (m.sender IS DISTINCT FROM ( SELECT policy.summarizer
                   FROM board.policy))) AS last_other_id
           FROM board.message m
          GROUP BY m.thread_id) t
     JOIN board.message r ON ((r.id = t.thread_id)))
     LEFT JOIN board.thread_summary s ON ((s.thread_id = t.thread_id)));


--
