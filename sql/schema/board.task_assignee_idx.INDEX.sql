-- Name: task_assignee_idx; Type: INDEX; Schema: board; Owner: -
--

CREATE INDEX task_assignee_idx ON board.task USING btree (assignee);


--
