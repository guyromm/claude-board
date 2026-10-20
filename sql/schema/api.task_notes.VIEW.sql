-- Name: task_notes; Type: VIEW; Schema: api; Owner: -
--

CREATE OR REPLACE VIEW api.task_notes AS
 SELECT id,
    task_id,
    author,
    body,
    change,
    created_at
   FROM board.task_note n;


--
