-- Name: thread_summary thread_summary_summarized_by_fkey; Type: FK CONSTRAINT; Schema: board; Owner: -
--

ALTER TABLE ONLY board.thread_summary
    ADD CONSTRAINT thread_summary_summarized_by_fkey FOREIGN KEY (summarized_by) REFERENCES board.agent(handle);


--
