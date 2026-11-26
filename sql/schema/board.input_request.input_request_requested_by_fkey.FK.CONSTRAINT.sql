-- Name: input_request input_request_requested_by_fkey; Type: FK CONSTRAINT; Schema: board; Owner: -
--

ALTER TABLE ONLY board.input_request
    ADD CONSTRAINT input_request_requested_by_fkey FOREIGN KEY (requested_by) REFERENCES board.agent(handle);


--
