-- Name: thread_link_other_idx; Type: INDEX; Schema: board; Owner: -
--

CREATE INDEX thread_link_other_idx ON board.thread_link USING btree (other_id);


--
