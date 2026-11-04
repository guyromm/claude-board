-- Name: message message_human_answered; Type: TRIGGER; Schema: board; Owner: -
--

CREATE TRIGGER message_human_answered AFTER INSERT ON board.message FOR EACH ROW EXECUTE FUNCTION board.message_human_answered();


--
