-- Name: project_client project_client_project_id_fkey; Type: FK CONSTRAINT; Schema: board; Owner: -
--

ALTER TABLE ONLY board.project_client
    ADD CONSTRAINT project_client_project_id_fkey FOREIGN KEY (project_id) REFERENCES board.task(id) ON DELETE CASCADE;


--
