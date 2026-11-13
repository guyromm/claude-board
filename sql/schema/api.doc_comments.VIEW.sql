-- Name: doc_comments; Type: VIEW; Schema: api; Owner: -
--

CREATE OR REPLACE VIEW api.doc_comments AS
 SELECT c.id,
    d.slug,
    c.version,
    c.quote,
    c.prefix,
    c.suffix,
    c.body,
    c.author,
    c.created_at,
    c.message_id,
    c.resolved_at,
    c.resolved_by
   FROM (board.doc_comment c
     JOIN board.doc d ON ((d.id = c.doc_id)));


--
