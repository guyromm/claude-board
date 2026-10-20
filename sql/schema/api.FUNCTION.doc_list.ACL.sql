-- Name: FUNCTION doc_list(); Type: ACL; Schema: api; Owner: -
--

REVOKE ALL ON FUNCTION api.doc_list() FROM PUBLIC;
GRANT ALL ON FUNCTION api.doc_list() TO board_agent;
GRANT ALL ON FUNCTION api.doc_list() TO board_admin;


--
