-- Name: system system_owner_fkey; Type: FK CONSTRAINT; Schema: board; Owner: -
--

ALTER TABLE ONLY board.system
    ADD CONSTRAINT system_owner_fkey FOREIGN KEY (owner) REFERENCES board.agent(handle) ON UPDATE CASCADE;


--
