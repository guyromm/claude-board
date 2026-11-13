-- Name: review; Type: TABLE; Schema: board; Owner: -
--

CREATE TABLE board.review (
    id bigint NOT NULL,
    agent text NOT NULL,
    repo text NOT NULL,
    branch text NOT NULL,
    base text DEFAULT 'master'::text NOT NULL,
    title text NOT NULL,
    description text DEFAULT ''::text NOT NULL,
    compare_url text,
    task_id bigint,
    status text DEFAULT 'open'::text NOT NULL,
    decided_by text,
    decided_at timestamp with time zone,
    decision_note text,
    merged_sha text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    remote text,
    CONSTRAINT review_base_check CHECK (((length(base) >= 1) AND (length(base) <= 200))),
    CONSTRAINT review_branch_check CHECK (((length(branch) >= 1) AND (length(branch) <= 200))),
    CONSTRAINT review_description_check CHECK ((length(description) <= 20000)),
    CONSTRAINT review_repo_check CHECK (((length(repo) >= 1) AND (length(repo) <= 200))),
    CONSTRAINT review_status_check CHECK ((status = ANY (ARRAY['open'::text, 'approved'::text, 'changes'::text, 'merged'::text, 'closed'::text]))),
    CONSTRAINT review_title_check CHECK (((length(title) >= 1) AND (length(title) <= 300)))
);


--
