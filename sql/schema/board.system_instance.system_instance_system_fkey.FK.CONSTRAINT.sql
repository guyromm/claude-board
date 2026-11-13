-- Name: system_instance system_instance_system_fkey; Type: FK CONSTRAINT; Schema: board; Owner: -
--

ALTER TABLE ONLY board.system_instance
    ADD CONSTRAINT system_instance_system_fkey FOREIGN KEY (system) REFERENCES board.system(slug) ON UPDATE CASCADE ON DELETE CASCADE;


--
