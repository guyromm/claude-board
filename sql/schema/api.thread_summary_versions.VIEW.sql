-- Name: thread_summary_versions; Type: VIEW; Schema: api; Owner: -
--

CREATE OR REPLACE VIEW api.thread_summary_versions AS
 SELECT id,
    thread_id,
    status,
    needs_human,
    human_reason,
    summary,
    summarized_through,
    summarized_at,
    summarized_by,
    source
   FROM board.thread_summary_version v;


--
