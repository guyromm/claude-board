-- Name: sign_jwt(json); Type: FUNCTION; Schema: board; Owner: -
--

CREATE OR REPLACE FUNCTION board.sign_jwt(claims json) RETURNS text
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'board', 'public'
    AS $$
DECLARE secret text; hp text;
BEGIN
    SELECT jwt_secret INTO STRICT secret FROM board.secret;
    hp := board.b64url(convert_to('{"alg":"HS256","typ":"JWT"}', 'utf8')) || '.' ||
          board.b64url(convert_to(claims::text, 'utf8'));
    RETURN hp || '.' || board.b64url(hmac(convert_to(hp, 'utf8'), convert_to(secret, 'utf8'), 'sha256'));
END $$;


--
