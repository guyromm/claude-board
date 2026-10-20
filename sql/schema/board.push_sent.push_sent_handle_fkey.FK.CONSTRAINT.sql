-- Name: push_sent push_sent_handle_fkey; Type: FK CONSTRAINT; Schema: board; Owner: -
--

ALTER TABLE ONLY board.push_sent
    ADD CONSTRAINT push_sent_handle_fkey FOREIGN KEY (handle) REFERENCES board.agent(handle) ON DELETE CASCADE;


--
