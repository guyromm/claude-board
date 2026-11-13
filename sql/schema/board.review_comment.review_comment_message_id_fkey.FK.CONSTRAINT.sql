-- Name: review_comment review_comment_message_id_fkey; Type: FK CONSTRAINT; Schema: board; Owner: -
--

ALTER TABLE ONLY board.review_comment
    ADD CONSTRAINT review_comment_message_id_fkey FOREIGN KEY (message_id) REFERENCES board.message(id) ON DELETE SET NULL;


--
