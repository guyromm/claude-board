-- Name: thread_summary_versioned(); Type: FUNCTION; Schema: board; Owner: -
--

CREATE OR REPLACE FUNCTION board.thread_summary_versioned() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF NEW.summary IS NOT NULL AND (TG_OP = 'INSERT' OR NEW.summarized_at IS DISTINCT FROM OLD.summarized_at) THEN
        INSERT INTO board.thread_summary_version (thread_id, status, needs_human, human_reason, summary,
                                                  summarized_through, summarized_at, summarized_by)
        VALUES (NEW.thread_id, NEW.status, NEW.needs_human, NEW.human_reason, NEW.summary,
                NEW.summarized_through, NEW.summarized_at, NEW.summarized_by);
    END IF;
    RETURN NULL;
END $$;


--
