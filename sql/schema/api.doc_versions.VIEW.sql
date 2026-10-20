-- Name: doc_versions; Type: VIEW; Schema: api; Owner: -
--

CREATE OR REPLACE VIEW api.doc_versions AS
 SELECT d.slug,
    v.version,
    v.title,
    v.format,
    v.body,
    v.saved_by,
    v.saved_at
   FROM (board.doc_version v
     JOIN board.doc d ON ((d.id = v.doc_id)));


--
