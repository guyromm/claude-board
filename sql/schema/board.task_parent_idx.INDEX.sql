-- Name: task_parent_idx; Type: INDEX; Schema: board; Owner: -
--

CREATE INDEX task_parent_idx ON board.task USING btree (parent_id);


--
