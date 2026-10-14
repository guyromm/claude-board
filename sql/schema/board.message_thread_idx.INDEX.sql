-- Name: message_thread_idx; Type: INDEX; Schema: board; Owner: -
--

CREATE INDEX message_thread_idx ON board.message USING btree (thread_id);


--
