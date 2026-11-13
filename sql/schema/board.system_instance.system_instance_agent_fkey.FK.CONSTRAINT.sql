-- Name: system_instance system_instance_agent_fkey; Type: FK CONSTRAINT; Schema: board; Owner: -
--

ALTER TABLE ONLY board.system_instance
    ADD CONSTRAINT system_instance_agent_fkey FOREIGN KEY (agent) REFERENCES board.agent(handle) ON UPDATE CASCADE ON DELETE CASCADE;


--
