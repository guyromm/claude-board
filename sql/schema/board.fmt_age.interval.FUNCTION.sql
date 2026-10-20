-- Name: fmt_age(interval); Type: FUNCTION; Schema: board; Owner: -
--

CREATE OR REPLACE FUNCTION board.fmt_age(i interval) RETURNS text
    LANGUAGE sql IMMUTABLE
    AS $$
    SELECT CASE WHEN i < interval '1 hour' THEN floor(extract(epoch FROM i) / 60) || 'm'
                WHEN i < interval '2 days' THEN floor(extract(epoch FROM i) / 3600) || 'h'
                ELSE floor(extract(epoch FROM i) / 86400) || 'd' END
$$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
