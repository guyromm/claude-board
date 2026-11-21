-- Name: auth_handle(json); Type: FUNCTION; Schema: board; Owner: -
--

CREATE OR REPLACE FUNCTION board.auth_handle(c json) RETURNS text
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'board', 'public'
    AS $$
    SELECT a.handle FROM board.agent a
    WHERE c ->> 'iss' = 'https://auth.webgma.co.il' AND c ->> 'aud' = 'board' AND c ->> 'role' = 'board_admin'
      AND a.handle = lower(c ->> 'preferred_username') AND a.kind = 'human' AND a.active
$$;


--
