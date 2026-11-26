// PostgREST client + session for the board UI. The API lives on the sibling host api.<this host>
// (board.example.com -> api.board.example.com); localhost dev talks to the local PostgREST.
export const API =
	location.hostname === 'localhost' || location.hostname === '127.0.0.1'
		? 'http://127.0.0.1:3070'
		: `${location.protocol}//api.${location.host}`;

const KEY = 'board.session';

// via 'auth': signed in through auth.webgma.co.il (#275/5); the token comes from /auth/token and is renewed by syncAuth
type Session = { handle: string; token: string; is_admin: boolean; via?: 'auth' } | null;

function load(): Session {
	try {
		const s = JSON.parse(localStorage.getItem(KEY) ?? 'null');
		if (!s?.token) return null;
		// drop expired tokens up front instead of failing every request
		const exp = JSON.parse(atob(s.token.split('.')[1].replace(/-/g, '+').replace(/_/g, '/'))).exp;
		return exp && exp * 1000 < Date.now() ? null : s;
	} catch {
		return null;
	}
}

export const session = $state<{ current: Session }>({ current: load() });

export function setSession(s: Session) {
	session.current = s;
	if (s) localStorage.setItem(KEY, JSON.stringify(s));
	else localStorage.removeItem(KEY);
}

// "Sign in with auth.webgma.co.il": the server keeps auth's cookies; /auth/token gives the current 15-min token,
// whoami maps it to a board handle (auth's board_admin grant -> the human row of the same username). Awaited by the
// root layout before any page redirects to /login, and renewed while it still has 5+ min left. A leftover
// password-login session (retired, #275/5; the API refuses its token now) is dropped.
// RENEWAL (entertainment #4807, 11-26: 7 of guy's chat messages were lost on a phone): a background tab's timers are
// suspended, so a plain 10-min interval let the 15-min token expire. Now a 1-min check renews when under 5 min are
// left, and returning to the tab (visibilitychange / focus) checks at once.
const expOf = (t: string | undefined): number => {
	try { return t ? JSON.parse(atob(t.split('.')[1].replace(/-/g, '+').replace(/_/g, '/'))).exp * 1000 : 0; } catch { return 0; }
};
let authTimer: ReturnType<typeof setInterval> | undefined;
let syncing: Promise<void> | null = null;
export function renewIfDue(): Promise<void> {
	if (session.current?.via !== 'auth' && session.current) return Promise.resolve();
	if (expOf(session.current?.token) - Date.now() > 5 * 60_000) return Promise.resolve();
	return syncAuth();
}
export function syncAuth(): Promise<void> {
	if (!authTimer && typeof window !== 'undefined') {
		authTimer = setInterval(() => void renewIfDue(), 60_000);
		const wake = () => { if (document.visibilityState === 'visible') void renewIfDue(); };
		document.addEventListener('visibilitychange', wake);
		window.addEventListener('focus', wake);
	}
	return (syncing ??= doSync().finally(() => (syncing = null)));
}
async function doSync(): Promise<void> {
	if (session.current && !session.current.via) setSession(null);
	try {
		const r = await fetch('/auth/token', { cache: 'no-store' });
		const token: string | null = r.ok ? (await r.json()).token : null;
		if (!token) {
			if (session.current?.via === 'auth') setSession(null);
			return;
		}
		const w = await fetch(API + '/rpc/whoami', { headers: { Accept: 'application/json', Authorization: `Bearer ${token}` } });
		if (!w.ok) {
			if (session.current?.via === 'auth') setSession(null);
			return;
		}
		const me = await w.json();
		setSession({ handle: me.handle, token, is_admin: !!me.is_admin, via: 'auth' });
	} catch {
		/* network hiccup: keep the current session, retry on the next tick */
	}
}

// signing out of an auth session drops board's auth cookies too (auth.webgma.co.il itself stays signed in)
export async function signOut() {
	const via = session.current?.via;
	setSession(null);
	// JSON body: SvelteKit's CSRF origin check only gates form posts, and this POST is same-origin anyway
	if (via === 'auth') await fetch('/auth/logout', { method: 'POST', redirect: 'manual', headers: { 'Content-Type': 'application/json' }, body: '{}' }).catch(() => {});
}

export class ApiError extends Error {
	constructor(
		message: string,
		public status: number,
		public hint?: string
	) {
		super(message);
	}
}

export async function api<T = any>(
	path: string,
	opts: { method?: string; body?: unknown; count?: boolean } = {}
): Promise<{ data: T; total: number | null }> {
	await renewIfDue();   // a token about to expire (phone tab back from the background) is renewed first
	const send = () => {
		const headers: Record<string, string> = { Accept: 'application/json' };
		if (session.current) headers.Authorization = `Bearer ${session.current.token}`;
		if (opts.body !== undefined) headers['Content-Type'] = 'application/json';
		if (opts.count) headers.Prefer = 'count=exact';
		return fetch(API + path, {
			method: opts.method ?? (opts.body !== undefined ? 'POST' : 'GET'),
			headers,
			body: opts.body !== undefined ? JSON.stringify(opts.body) : undefined
		});
	};
	let res = await send();
	// 401 on an auth session: renew once and retry before giving up (the write must not be lost)
	if (res.status === 401 && session.current?.via === 'auth') { await syncAuth(); if (session.current) res = await send(); }
	const text = await res.text();
	const data = text ? JSON.parse(text) : null;
	if (!res.ok) {
		if (res.status === 401 || data?.code === '28000') setSession(null);
		throw new ApiError(data?.message ?? res.statusText, res.status, data?.hint ?? undefined);
	}
	const range = res.headers.get('Content-Range');
	const total = range && range.includes('/') ? Number(range.split('/')[1]) : null;
	return { data, total: Number.isFinite(total) ? total : null };
}

// handle -> claude-ui chat URL (board.agent.claude_ui_url), loaded once: Body links "<handle>'s session"
// and "<handle>'s chat" in escalations and summaries to the agent's chat
export const chatUrls = $state<{ map: Map<string, string> }>({ map: new Map() });
let chatLoad: Promise<void> | null = null;
export function loadChatUrls() {
	chatLoad ??= api<{ handle: string; claude_ui_url: string }[]>('/agents?select=handle,claude_ui_url&claude_ui_url=not.is.null')
		.then((r) => { chatUrls.map = new Map(r.data.map((a) => [a.handle, a.claude_ui_url])); })
		.catch(() => { chatLoad = null; });
}

export type Message = {
	id: number;
	sender: string;
	sender_system: string | null;
	subject: string;
	body: string;
	tags: string[];
	systems: string[];
	reply_to: number | null;
	thread_id: number;
	created_at: string;
	recipients: string[];
	my_read_at: string | null;
	to_me: boolean;
	thread_size: number;
};

export type ThreadSummary = {
	thread_id: number;
	status: 'open' | 'closed' | null; // null: never summarized
	needs_human: boolean;
	human_reason: string | null;
	summary: string | null;
	summarized_through: number | null;
	summarized_at: string | null;
	summarized_by: string | null;
	stale: boolean; // others posted after the summary was written
	read_only_reason: string | null; // set: only admins and the PM agent may post in the thread
};
export const SUMMARY_COLS =
	'thread_id,status,needs_human,human_reason,summary,summarized_through,summarized_at,summarized_by,stale,read_only_reason';

export type Agent = {
	handle: string;
	kind: 'agent' | 'human';
	display_name: string | null;
	host: string | null;
	tmux_target: string | null;
	system: string | null;
	description: string | null;
	responsibilities: string | null;
	goals: string | null;
	is_admin: boolean;
	active: boolean;
	created_at: string;
	last_seen_at: string | null;
	sent_count: number;
	received_count: number;
	session_state: SessionState | null; // the agent's Claude session, as its watcher sees it
	session_detail: string | null;
	session_checked_at: string | null;
	session_changed_at: string | null;
	watcher_version: number | null;
	claude_ui_url: string | null; // the agent's claude-ui (web/phone UI onto its Claude session)
	claude_model: string | null; // the session's model id, e.g. claude-opus-5-5 (watcher v13+)
	claude_version: string | null; // its Claude Code version, e.g. 2.1.312
	claude_info_at: string | null;
	offline_ok: boolean; // an admin marked it fine to be offline: a silent watcher is no warning
};

// "claude-opus-5-5" / "claude-sonnet-4-5-20250929" -> "Opus 5.5" / "Sonnet 4.5"; anything else as is
export const modelName = (id: string) => {
	const m = /^claude-([a-z]+)-(\d+)(?:-(\d{1,2}))?(?:-\d{8})?$/.exec(id);
	return m ? `${m[1][0].toUpperCase()}${m[1].slice(1)} ${m[2]}${m[3] ? '.' + m[3] : ''}` : id;
};

export const MESSAGE_COLS =
	'id,sender,sender_system,subject,body,tags,systems,reply_to,thread_id,created_at,recipients,my_read_at,to_me,thread_size';

// PostgREST array literal element: quote anything that is not a bare word
export const pgEl = (s: string) => (/^[\w.-]+$/.test(s) ? s : `"${s.replace(/["\\]/g, '\\$&')}"`);

export function ago(ts: string | null): string {
	if (!ts) return 'never';
	const s = (Date.now() - new Date(ts).getTime()) / 1000;
	if (s < 60) return 'just now';
	if (s < 3600) return `${Math.floor(s / 60)}m ago`;
	if (s < 86400) return `${Math.floor(s / 3600)}h ago`;
	if (s < 86400 * 30) return `${Math.floor(s / 86400)}d ago`;
	return new Date(ts).toLocaleDateString();
}

export const fmtTime = (ts: string) =>
	new Date(ts).toLocaleString(undefined, { dateStyle: 'medium', timeStyle: 'short' });

// a Claude session that can't take notifications until a human acts (reported by the agent's watcher)
export type SessionState = 'ok' | 'logged_out' | 'needs_input' | 'no_claude';
export const SESSION_PROBLEM: Record<string, string> = {
	logged_out: 'Claude session logged out',
	needs_input: 'waiting for a human: a question or dialog is open in its Claude session',
	no_claude: "Claude isn't running in its pane"
};
export const sessionBlocked = (a: { active: boolean; kind: string; session_state: string | null }) =>
	a.active && a.kind === 'agent' && !!a.session_state && a.session_state in SESSION_PROBLEM;
// a watcher polls every ~10 s and bumps last_seen_at; silent this long = dead watcher, host down or offline
export const WATCHER_SILENT_MS = 10 * 60_000;
export const watcherSilent = (a: { active: boolean; kind: string; last_seen_at: string | null; offline_ok?: boolean }) =>
	a.active && a.kind === 'agent' && !a.offline_ok && (!a.last_seen_at || Date.now() - new Date(a.last_seen_at).getTime() > WATCHER_SILENT_MS);

// tasks (kanban): see board.task in sql/bootstrap.sql
export const TASK_STATUSES = ['todo', 'doing', 'blocked', 'ongoing', 'review', 'done'] as const; // board columns; 'cancelled' is hidden
export type TaskStatus = (typeof TASK_STATUSES)[number] | 'cancelled';
export const TASK_LABEL: Record<TaskStatus, string> = {
	ongoing: 'Ongoing', todo: 'To do', doing: 'Doing', blocked: 'Blocked', review: 'Review', done: 'Done', cancelled: 'Cancelled'
};
export type Task = {
	id: number;
	parent_id: number | null;
	title: string;
	description: string;
	status: TaskStatus;
	assignee: string | null;
	created_by: string;
	check_every: string;
	due_at: string | null;
	needs_human: boolean;
	human_reason: string | null;
	position: number;
	created_at: string;
	updated_at: string;
	status_changed_at: string;
	activity_at: string;
	pm_prompted_at: string | null;
	overdue_checkin: boolean; // open, and no activity for check_every
	subtasks: number;
	subtasks_done: number;
	threads: number[];
	notes: number;
	last_note: string | null;
	path: string; // semantic id: "119" top level, "119/3" its 3rd subtask (board.task.path)
	umbrella: boolean; // cross-project top-level task (#119/): its subtasks belong to their assignees' projects
	// doc:systems-and-projects: a project node (kind 'project', with slug/url) or a task; a task belongs to its
	// nearest project node (project_id), else to the system it names (system work), else to Operations
	kind: 'task' | 'project';
	slug: string | null;
	url: string | null;
	system: string | null;
	project_id: number | null;
	assignee_system: string | null; // the system its assignee runs (labels #119/-style umbrella subtasks)
	human_level: 1 | 2 | 3; // how urgent its "needs you" is: 1 urgent, 2 soon, 3 whenever (api.task_urgency)
};
export const HUMAN_LEVEL = ['', 'Urgent', 'Soon', 'Whenever'] as const;
export type ProjectInfo = { id: number; path: string; slug: string; title: string; status: TaskStatus; lead: string | null;
	url: string | null; description: string | null; parent_project_id: number | null;
	systems: { system: string; role: string }[];
	clients: { client: string; name: string; for_client: string | null; for_name: string | null; inherited: boolean }[];
	open_tasks: number; needs_you: number };
export type SystemInfo = { slug: string; name: string; kind: string; owner: string | null; repo: string | null; description: string | null;
	instances: { agent: string; label: string | null; host: string | null }[];
	projects: { id: number; path: string; slug: string | null; title: string; role: string }[]; open_tasks: number };
// how a task is written and linked: "#119/" (top level; bare "#119" is a message) or "#119/3"
export const taskRef = (t: { path: string; parent_id: number | null }) => `#${t.path}${t.parent_id ? '' : '/'}`;
export const taskHref = (t: { path: string }) => `/tasks/${t.path}`;
export type TaskNote = { id: number; task_id: number; author: string; body: string; change: string | null; created_at: string };
// one escalation ("needs you") and how it ended (api.task_escalations)
export type TaskEscalation = {
	id: number; task_id: number; task_title: string; task_status: TaskStatus; raised_by: string; raised_at: string;
	reason: string; ended_at: string | null; ended_by: string | null; outcome: 'open' | 'answered' | 'cleared' | 'reworded';
	answer: string | null;
};
export type TaskThread = {
	task_id: number; thread_id: number; linked_by: string; linked_at: string; subject: string;
	last_at: string; size: number; status: 'open' | 'closed' | null; needs_human: boolean; summary: string | null;
};
