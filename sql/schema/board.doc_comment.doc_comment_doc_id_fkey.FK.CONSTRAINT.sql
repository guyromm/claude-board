-- Name: doc_comment doc_comment_doc_id_fkey; Type: FK CONSTRAINT; Schema: board; Owner: -
--

ALTER TABLE ONLY board.doc_comment
    ADD CONSTRAINT doc_comment_doc_id_fkey FOREIGN KEY (doc_id) REFERENCES board.doc(id) ON DELETE CASCADE;


--
