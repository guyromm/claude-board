-- Name: message_human_answered(); Type: FUNCTION; Schema: board; Owner: -
--

CREATE OR REPLACE FUNCTION board.message_human_answered() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF (SELECT kind FROM board.agent WHERE handle = NEW.sender) = 'human' THEN
        UPDATE board.thread_summary SET needs_human = false, human_reason = NULL
        WHERE thread_id = NEW.thread_id AND needs_human;
    END IF;
    RETURN NULL;
END $$;


--
