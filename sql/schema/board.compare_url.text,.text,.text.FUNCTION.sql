-- Name: compare_url(text, text, text); Type: FUNCTION; Schema: board; Owner: -
--

CREATE OR REPLACE FUNCTION board.compare_url(u text, base text, branch text) RETURNS text
    LANGUAGE sql IMMUTABLE
    AS $$
    SELECT CASE
        WHEN u ~* 'github\.com' THEN 'https://github.com/' || board.remote_repo(u) || '/compare/' || base || '...' || branch
        WHEN u ~* 'gitlab\.com' THEN 'https://gitlab.com/' || board.remote_repo(u) || '/-/compare/' || base || '...' || branch
        WHEN u ~* '(gma8|git\.webgma\.co\.il)' THEN 'https://git.webgma.co.il/' || board.remote_repo(u) || '/compare/' || base || '...' || branch
    END
$$;


--
