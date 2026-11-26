-- Name: input_request input_request_handle_fkey; Type: FK CONSTRAINT; Schema: board; Owner: -
--

ALTER TABLE ONLY board.input_request
    ADD CONSTRAINT input_request_handle_fkey FOREIGN KEY (handle) REFERENCES board.agent(handle);


--
