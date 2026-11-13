-- Name: review_revs; Type: VIEW; Schema: api; Owner: -
--

CREATE OR REPLACE VIEW api.review_revs AS
 SELECT review_id,
    rev,
    head_sha,
    base_sha,
    diff,
    files,
    adds,
    dels,
    note,
    created_at
   FROM board.review_rev;


--
