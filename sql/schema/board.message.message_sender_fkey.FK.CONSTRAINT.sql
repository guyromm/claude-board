-- Name: message message_sender_fkey; Type: FK CONSTRAINT; Schema: board; Owner: -
--

ALTER TABLE ONLY board.message
    ADD CONSTRAINT message_sender_fkey FOREIGN KEY (sender) REFERENCES board.agent(handle);


--
