-- Name: COLUMN claude_session.who; Type: COMMENT; Schema: board; Owner: -
--

COMMENT ON COLUMN board.claude_session.who IS 'the JWT''s name claim, else email, else sub (same as claude_msg.sender)';


--
