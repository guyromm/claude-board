-- Name: login_request login_request_requested_by_fkey; Type: FK CONSTRAINT; Schema: board; Owner: -
--

ALTER TABLE ONLY board.login_request
    ADD CONSTRAINT login_request_requested_by_fkey FOREIGN KEY (requested_by) REFERENCES board.agent(handle);


--
