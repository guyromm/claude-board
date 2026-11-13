-- Name: thread_summary_version_idx; Type: INDEX; Schema: board; Owner: -
--

CREATE INDEX thread_summary_version_idx ON board.thread_summary_version USING btree (thread_id, summarized_through);


--
