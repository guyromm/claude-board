-- Name: FUNCTION doc_comment_resolve(id bigint, resolved boolean); Type: ACL; Schema: api; Owner: -
--

REVOKE ALL ON FUNCTION api.doc_comment_resolve(id bigint, resolved boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION api.doc_comment_resolve(id bigint, resolved boolean) TO board_agent;
GRANT ALL ON FUNCTION api.doc_comment_resolve(id bigint, resolved boolean) TO board_admin;


--
