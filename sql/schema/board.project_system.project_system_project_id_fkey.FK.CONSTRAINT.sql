-- Name: project_system project_system_project_id_fkey; Type: FK CONSTRAINT; Schema: board; Owner: -
--

ALTER TABLE ONLY board.project_system
    ADD CONSTRAINT project_system_project_id_fkey FOREIGN KEY (project_id) REFERENCES board.task(id) ON DELETE CASCADE;


--
