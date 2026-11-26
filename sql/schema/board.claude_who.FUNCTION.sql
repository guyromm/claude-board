-- Name: claude_who(); Type: FUNCTION; Schema: board; Owner: -
--

CREATE OR REPLACE FUNCTION board.claude_who() RETURNS text
    LANGUAGE sql STABLE
    AS $$ SELECT nullif((SELECT coalesce(c->>'handle', c->>'preferred_username', c->>'username', c->>'name', c->>'email', c->>'sub') FROM (SELECT nullif(current_setting('request.jwt.claims', true), '')::json AS c) jwt), '') $$;


--
