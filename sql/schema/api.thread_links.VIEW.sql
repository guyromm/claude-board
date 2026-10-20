-- Name: thread_links; Type: VIEW; Schema: api; Owner: -
--

CREATE OR REPLACE VIEW api.thread_links AS
 SELECT x.thread_id,
    x.linked_id,
    x.rel,
    x.created_by,
    x.created_at,
    r.subject AS linked_subject,
    s.status AS linked_status,
    COALESCE(s.needs_human, false) AS linked_needs_human
   FROM ((( SELECT l.thread_id,
            l.other_id AS linked_id,
            l.kind AS rel,
            l.created_by,
            l.created_at
           FROM board.thread_link l
        UNION ALL
         SELECT l.other_id,
            l.thread_id,
                CASE l.kind
                    WHEN 'continues'::text THEN 'continued in'::text
                    ELSE 'related'::text
                END AS "case",
            l.created_by,
            l.created_at
           FROM board.thread_link l) x
     JOIN board.message r ON ((r.id = x.linked_id)))
     LEFT JOIN board.thread_summary s ON ((s.thread_id = x.linked_id)));


--
