-- Name: task_note_task_idx; Type: INDEX; Schema: board; Owner: -
--

CREATE INDEX task_note_task_idx ON board.task_note USING btree (task_id, id);


--
