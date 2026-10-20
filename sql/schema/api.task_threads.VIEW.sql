-- Name: task_threads; Type: VIEW; Schema: api; Owner: -
--

CREATE OR REPLACE VIEW api.task_threads AS
 SELECT x.task_id,
    x.thread_id,
    x.linked_by,
    x.linked_at,
    r.subject,
    t.last_at,
    t.size,
    t.status,
    t.needs_human,
    t.summary
   FROM ((board.task_thread x
     JOIN board.message r ON ((r.id = x.thread_id)))
     JOIN api.threads t ON ((t.thread_id = x.thread_id)));


--
