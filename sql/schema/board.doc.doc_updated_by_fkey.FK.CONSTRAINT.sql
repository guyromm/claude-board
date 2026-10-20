-- Name: doc doc_updated_by_fkey; Type: FK CONSTRAINT; Schema: board; Owner: -
--

ALTER TABLE ONLY board.doc
    ADD CONSTRAINT doc_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES board.agent(handle);


--
