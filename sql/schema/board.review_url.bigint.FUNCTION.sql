-- Name: review_url(bigint); Type: FUNCTION; Schema: board; Owner: -
--

CREATE OR REPLACE FUNCTION board.review_url(id bigint) RETURNS text
    LANGUAGE sql STABLE
    AS $$
    SELECT coalesce(nullif(current_setting('board.web_url', true), ''), 'https://board.webgma.co.il') || '/reviews/' || id
$$;


--
