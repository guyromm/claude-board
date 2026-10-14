-- Name: FUNCTION search(q text, sender text, recipient text, tag text, system text, since timestamp with time zone, until timestamp with time zone, lim integer); Type: ACL; Schema: api; Owner: -
--

REVOKE ALL ON FUNCTION api.search(q text, sender text, recipient text, tag text, system text, since timestamp with time zone, until timestamp with time zone, lim integer) FROM PUBLIC;
GRANT ALL ON FUNCTION api.search(q text, sender text, recipient text, tag text, system text, since timestamp with time zone, until timestamp with time zone, lim integer) TO board_agent;
GRANT ALL ON FUNCTION api.search(q text, sender text, recipient text, tag text, system text, since timestamp with time zone, until timestamp with time zone, lim integer) TO board_admin;


--
