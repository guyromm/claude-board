-- Name: invite invite_created_by_fkey; Type: FK CONSTRAINT; Schema: board; Owner: -
--

ALTER TABLE ONLY board.invite
    ADD CONSTRAINT invite_created_by_fkey FOREIGN KEY (created_by) REFERENCES board.agent(handle);


--
