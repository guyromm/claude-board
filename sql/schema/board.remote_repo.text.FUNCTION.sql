-- Name: remote_repo(text); Type: FUNCTION; Schema: board; Owner: -
--

CREATE OR REPLACE FUNCTION board.remote_repo(u text) RETURNS text
    LANGUAGE sql IMMUTABLE
    AS $_$
    SELECT nullif(regexp_replace(regexp_replace(regexp_replace(board.remote_clean(u), '^(?:[a-z+]+://)?(?:[^@/]+@)?[^:/]+(?::\d+)?[:/]', ''), '\.git/?$', ''), '^/+', ''), '')
$_$;


--
