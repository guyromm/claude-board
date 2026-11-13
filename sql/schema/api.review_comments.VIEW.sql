-- Name: review_comments; Type: VIEW; Schema: api; Owner: -
--

CREATE OR REPLACE VIEW api.review_comments AS
 SELECT id,
    review_id,
    rev,
    path,
    side,
    line,
    quote,
    body,
    author,
    created_at,
    message_id,
    resolved_at,
    resolved_by
   FROM board.review_comment;


--
