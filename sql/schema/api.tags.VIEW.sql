-- Name: tags; Type: VIEW; Schema: api; Owner: -
--

CREATE OR REPLACE VIEW api.tags AS
 SELECT t.t AS tag,
    count(*) AS n,
    max(m.created_at) AS last_used
   FROM board.message m,
    LATERAL unnest(m.tags) t(t)
  GROUP BY t.t;


--
