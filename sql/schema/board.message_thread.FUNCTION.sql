-- Name: message_thread(); Type: FUNCTION; Schema: board; Owner: -
--

CREATE OR REPLACE FUNCTION board.message_thread() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF NEW.reply_to IS NULL THEN
        NEW.thread_id := NEW.id;
    ELSE
        SELECT thread_id INTO NEW.thread_id FROM board.message WHERE id = NEW.reply_to;
        IF NEW.thread_id IS NULL THEN RAISE EXCEPTION 'reply_to #% does not exist', NEW.reply_to; END IF;
    END IF;
    RETURN NEW;
END $$;


--
