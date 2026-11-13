-- Name: project_system project_system_system_fkey; Type: FK CONSTRAINT; Schema: board; Owner: -
--

ALTER TABLE ONLY board.project_system
    ADD CONSTRAINT project_system_system_fkey FOREIGN KEY (system) REFERENCES board.system(slug) ON UPDATE CASCADE ON DELETE CASCADE;


--
