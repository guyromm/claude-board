-- Name: task; Type: TABLE; Schema: board; Owner: -
--

CREATE TABLE board.task (
    id bigint NOT NULL,
    parent_id bigint,
    title text NOT NULL,
    description text DEFAULT ''::text NOT NULL,
    status text DEFAULT 'todo'::text NOT NULL,
    assignee text,
    created_by text NOT NULL,
    check_every interval DEFAULT '1 day'::interval NOT NULL,
    due_at timestamp with time zone,
    needs_human boolean DEFAULT false NOT NULL,
    human_reason text,
    "position" double precision DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    status_changed_at timestamp with time zone DEFAULT now() NOT NULL,
    activity_at timestamp with time zone DEFAULT now() NOT NULL,
    assignee_notified_at timestamp with time zone,
    pm_prompted_at timestamp with time zone,
    path text NOT NULL,
    seq integer,
    child_seq integer DEFAULT 0 NOT NULL,
    umbrella boolean DEFAULT false NOT NULL,
    kind text DEFAULT 'task'::text NOT NULL,
    slug text,
    url text,
    system text,
    human_level smallint DEFAULT 2 NOT NULL,
    CONSTRAINT task_check_every_check CHECK ((check_every >= '00:10:00'::interval)),
    CONSTRAINT task_description_check CHECK ((length(description) <= 20000)),
    CONSTRAINT task_human_level_check CHECK (((human_level >= 1) AND (human_level <= 3))),
    CONSTRAINT task_kind_check CHECK ((kind = ANY (ARRAY['task'::text, 'project'::text]))),
    CONSTRAINT task_ongoing_daily CHECK (((status <> 'ongoing'::text) OR (check_every <= '1 day'::interval))),
    CONSTRAINT task_status_check CHECK ((status = ANY (ARRAY['todo'::text, 'doing'::text, 'blocked'::text, 'review'::text, 'done'::text, 'cancelled'::text, 'ongoing'::text]))),
    CONSTRAINT task_title_check CHECK (((length(title) >= 1) AND (length(title) <= 300)))
);


--
