-- Name: recipient recipient_handle_fkey; Type: FK CONSTRAINT; Schema: board; Owner: -
--

ALTER TABLE ONLY board.recipient
    ADD CONSTRAINT recipient_handle_fkey FOREIGN KEY (handle) REFERENCES board.agent(handle);


--
