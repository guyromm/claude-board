-- Name: message_stats; Type: VIEW; Schema: api; Owner: -
--

CREATE OR REPLACE VIEW api.message_stats AS
 SELECT id,
    sender,
    thread_id,
    created_at,
    subject,
    (octet_length(COALESCE(subject, ''::text)) + octet_length(body)) AS bytes,
    COALESCE(( SELECT array_agg(r.handle ORDER BY r.handle) AS array_agg
           FROM board.recipient r
          WHERE (r.message_id = m.id)), '{}'::text[]) AS recipients,
    COALESCE(( SELECT array_agg(x.task_id ORDER BY x.task_id) AS array_agg
           FROM board.task_thread x
          WHERE (x.thread_id = m.thread_id)), '{}'::bigint[]) AS task_ids
   FROM board.message m;


--
