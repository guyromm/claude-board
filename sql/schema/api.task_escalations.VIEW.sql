-- Name: task_escalations; Type: VIEW; Schema: api; Owner: -
--

CREATE OR REPLACE VIEW api.task_escalations AS
 WITH ev AS (
         SELECT n.id,
            n.task_id,
            n.author,
            n.body,
            n.created_at,
                CASE
                    WHEN (n.change ~ 'escalated to the human: '::text) THEN 'raised'::text
                    WHEN (n.change ~ 'escalation answered by '::text) THEN 'answered'::text
                    ELSE 'cleared'::text
                END AS kind,
            "substring"(n.change, 'escalated to the human: (.*)$'::text) AS reason
           FROM board.task_note n
          WHERE (n.change ~ '(escalated to the human: |escalation answered by |escalation cleared)'::text)
        )
 SELECT r.id,
    r.task_id,
    t.title AS task_title,
    t.status AS task_status,
    r.author AS raised_by,
    r.created_at AS raised_at,
    r.reason,
    e.created_at AS ended_at,
    e.author AS ended_by,
        CASE
            WHEN (e.id IS NULL) THEN 'open'::text
            WHEN (e.kind = 'raised'::text) THEN 'reworded'::text
            ELSE e.kind
        END AS outcome,
        CASE
            WHEN (e.kind = 'answered'::text) THEN NULLIF(e.body, ''::text)
            ELSE NULL::text
        END AS answer
   FROM ((ev r
     JOIN board.task t ON ((t.id = r.task_id)))
     LEFT JOIN LATERAL ( SELECT x.id,
            x.task_id,
            x.author,
            x.body,
            x.created_at,
            x.kind,
            x.reason
           FROM ev x
          WHERE ((x.task_id = r.task_id) AND (x.id > r.id))
          ORDER BY x.id
         LIMIT 1) e ON (true))
  WHERE (r.kind = 'raised'::text);


--
