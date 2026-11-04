-- Name: task_path_idx; Type: INDEX; Schema: board; Owner: -
--

CREATE UNIQUE INDEX task_path_idx ON board.task USING btree (path);


--
