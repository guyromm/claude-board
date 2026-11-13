-- Name: doc_comment doc_comment_message_id_fkey; Type: FK CONSTRAINT; Schema: board; Owner: -
--

ALTER TABLE ONLY board.doc_comment
    ADD CONSTRAINT doc_comment_message_id_fkey FOREIGN KEY (message_id) REFERENCES board.message(id) ON DELETE SET NULL;


--
