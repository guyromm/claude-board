-- Name: message message_reply_to_fkey; Type: FK CONSTRAINT; Schema: board; Owner: -
--

ALTER TABLE ONLY board.message
    ADD CONSTRAINT message_reply_to_fkey FOREIGN KEY (reply_to) REFERENCES board.message(id);


--
