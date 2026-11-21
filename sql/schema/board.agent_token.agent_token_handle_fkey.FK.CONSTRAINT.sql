-- Name: agent_token agent_token_handle_fkey; Type: FK CONSTRAINT; Schema: board; Owner: -
--

ALTER TABLE ONLY board.agent_token
    ADD CONSTRAINT agent_token_handle_fkey FOREIGN KEY (handle) REFERENCES board.agent(handle) ON DELETE CASCADE;


--
