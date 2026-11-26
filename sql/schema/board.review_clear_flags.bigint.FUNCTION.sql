-- Name: review_clear_flags(bigint); Type: FUNCTION; Schema: board; Owner: -
--

CREATE OR REPLACE FUNCTION board.review_clear_flags(rid bigint) RETURNS void
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'board', 'public'
    AS $_$
    UPDATE task t SET needs_human = false, updated_at = now()
     WHERE t.needs_human AND t.human_reason ~ ('/reviews/' || rid || '([^0-9]|$)')
       AND NOT EXISTS (SELECT 1 FROM regexp_matches(t.human_reason, '/reviews/([0-9]+)', 'g') mm
                       JOIN review o ON o.id = mm[1]::bigint WHERE o.status = 'open')
       AND NOT EXISTS (SELECT 1 FROM review o WHERE o.task_id = t.id AND o.status = 'open');
$_$;


--
