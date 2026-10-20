-- Name: doc_version doc_version_doc_id_fkey; Type: FK CONSTRAINT; Schema: board; Owner: -
--

ALTER TABLE ONLY board.doc_version
    ADD CONSTRAINT doc_version_doc_id_fkey FOREIGN KEY (doc_id) REFERENCES board.doc(id) ON DELETE CASCADE;


--
