-- Name: activity_minute activity_minute_handle_fkey; Type: FK CONSTRAINT; Schema: board; Owner: -
--

ALTER TABLE ONLY board.activity_minute
    ADD CONSTRAINT activity_minute_handle_fkey FOREIGN KEY (handle) REFERENCES board.agent(handle) ON UPDATE CASCADE ON DELETE CASCADE;


--
