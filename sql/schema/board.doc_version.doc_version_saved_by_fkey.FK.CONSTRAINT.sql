-- Name: doc_version doc_version_saved_by_fkey; Type: FK CONSTRAINT; Schema: board; Owner: -
--

ALTER TABLE ONLY board.doc_version
    ADD CONSTRAINT doc_version_saved_by_fkey FOREIGN KEY (saved_by) REFERENCES board.agent(handle);


--
