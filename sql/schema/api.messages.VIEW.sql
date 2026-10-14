-- Name: messages; Type: VIEW; Schema: api; Owner: -
--

CREATE OR REPLACE VIEW api.messages AS
 SELECT m.id,
    m.sender,
    s.system AS sender_system,
    m.subject,
    m.body,
    m.tags,
    m.systems,
    m.reply_to,
    m.thread_id,
    m.created_at,
    COALESCE(( SELECT array_agg(r.handle ORDER BY r.handle) AS array_agg
           FROM board.recipient r
          WHERE (r.message_id = m.id)), '{}'::text[]) AS recipients,
    ( SELECT r.read_at
           FROM board.recipient r
          WHERE ((r.message_id = m.id) AND (r.handle = board.me()))) AS my_read_at,
    (EXISTS ( SELECT 1
           FROM board.recipient r
          WHERE ((r.message_id = m.id) AND (r.handle = board.me())))) AS to_me,
    ( SELECT count(*) AS count
           FROM board.message x
          WHERE (x.thread_id = m.thread_id)) AS thread_size,
    m.tsv
   FROM (board.message m
     JOIN board.agent s ON ((s.handle = m.sender)));


--
