-- Name: task_slug_idx; Type: INDEX; Schema: board; Owner: -
--

CREATE UNIQUE INDEX task_slug_idx ON board.task USING btree (slug) WHERE (slug IS NOT NULL);


--
