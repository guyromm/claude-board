-- Name: tasks; Type: VIEW; Schema: api; Owner: -
--

CREATE OR REPLACE VIEW api.tasks AS
 SELECT id,
    parent_id,
    title,
    description,
    status,
    assignee,
    created_by,
    (check_every)::text AS check_every,
    due_at,
    needs_human,
    human_reason,
    "position",
    created_at,
    updated_at,
    status_changed_at,
    activity_at,
    pm_prompted_at,
    ((status <> ALL (ARRAY['done'::text, 'cancelled'::text])) AND (activity_at < (now() - check_every))) AS overdue_checkin,
    ( SELECT count(*) AS count
           FROM board.task c
          WHERE ((c.parent_id = t.id) AND (c.status <> 'cancelled'::text))) AS subtasks,
    ( SELECT count(*) AS count
           FROM board.task c
          WHERE ((c.parent_id = t.id) AND (c.status = 'done'::text))) AS subtasks_done,
    COALESCE(( SELECT array_agg(x.thread_id ORDER BY x.thread_id) AS array_agg
           FROM board.task_thread x
          WHERE (x.task_id = t.id)), '{}'::bigint[]) AS threads,
    ( SELECT count(*) AS count
           FROM board.task_note n
          WHERE (n.task_id = t.id)) AS notes,
    ( SELECT n.body
           FROM board.task_note n
          WHERE ((n.task_id = t.id) AND (n.body <> ''::text))
          ORDER BY n.id DESC
         LIMIT 1) AS last_note,
    path
   FROM board.task t;


--
