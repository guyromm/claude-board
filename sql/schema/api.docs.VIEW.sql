-- Name: docs; Type: VIEW; Schema: api; Owner: -
--

CREATE OR REPLACE VIEW api.docs AS
 SELECT id,
    slug,
    title,
    format,
    body,
    version,
    created_by,
    created_at,
    updated_by,
    updated_at,
    length(body) AS size
   FROM board.doc d;


--
