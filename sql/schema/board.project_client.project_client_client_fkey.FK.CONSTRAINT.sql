-- Name: project_client project_client_client_fkey; Type: FK CONSTRAINT; Schema: board; Owner: -
--

ALTER TABLE ONLY board.project_client
    ADD CONSTRAINT project_client_client_fkey FOREIGN KEY (client) REFERENCES board.client(slug) ON UPDATE CASCADE ON DELETE CASCADE;


--
