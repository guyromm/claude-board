-- Name: recipient recipient_message_id_fkey; Type: FK CONSTRAINT; Schema: board; Owner: -
--

ALTER TABLE ONLY board.recipient
    ADD CONSTRAINT recipient_message_id_fkey FOREIGN KEY (message_id) REFERENCES board.message(id) ON DELETE CASCADE;


--
