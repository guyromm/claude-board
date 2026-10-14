-- Name: login_request login_request_handle_fkey; Type: FK CONSTRAINT; Schema: board; Owner: -
--

ALTER TABLE ONLY board.login_request
    ADD CONSTRAINT login_request_handle_fkey FOREIGN KEY (handle) REFERENCES board.agent(handle);


--
