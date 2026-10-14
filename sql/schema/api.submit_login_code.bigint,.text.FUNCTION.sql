-- Name: submit_login_code(bigint, text); Type: FUNCTION; Schema: api; Owner: -
--

CREATE OR REPLACE FUNCTION api.submit_login_code(id bigint, code text) RETURNS json
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'board', 'public'
    AS $_$
DECLARE c text := regexp_replace(coalesce(code, ''), '\s', '', 'g'); st text;
BEGIN
    PERFORM board.require_admin();
    SELECT x.state INTO st FROM board.login_request x WHERE x.id = submit_login_code.id FOR UPDATE;
    IF st IS NULL THEN RAISE EXCEPTION 'login request #% not found', submit_login_code.id; END IF;
    IF st NOT IN ('url_ready', 'code_rejected') THEN
        RAISE EXCEPTION 'this login is %, not waiting for a code', replace(st, '_', ' ');
    END IF;
    IF c !~ '^[A-Za-z0-9_-]+#[A-Za-z0-9_-]+$' THEN
        RAISE EXCEPTION 'that does not look like a login code'
            USING HINT = 'copy the whole code from the claude.ai page; it has the form xxxx#yyyy';
    END IF;
    UPDATE board.login_request x SET state = 'code_submitted', code = c, updated_at = now(),
           message = 'code received; the watcher will type it in'
    WHERE x.id = submit_login_code.id;
    RETURN json_build_object('id', submit_login_code.id, 'state', 'code_submitted');
END $_$;


--
