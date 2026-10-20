-- Name: FUNCTION doc_save(slug text, body text, title text, format text); Type: ACL; Schema: api; Owner: -
--

REVOKE ALL ON FUNCTION api.doc_save(slug text, body text, title text, format text) FROM PUBLIC;
GRANT ALL ON FUNCTION api.doc_save(slug text, body text, title text, format text) TO board_agent;
GRANT ALL ON FUNCTION api.doc_save(slug text, body text, title text, format text) TO board_admin;


--
