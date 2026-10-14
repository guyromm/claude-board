-- Name: message message_thread; Type: TRIGGER; Schema: board; Owner: -
--

CREATE TRIGGER message_thread BEFORE INSERT ON board.message FOR EACH ROW EXECUTE FUNCTION board.message_thread();


--
