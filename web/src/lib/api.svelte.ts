// PostgREST client + session for the board UI. The API lives on the sibling host api.<this host>
// (board.example.com -> api.board.example.com); localhost dev talks to the local PostgREST.
export const API =
	location.hostname === 'localhost' || location.hostname === '127.0.0.1'
		? 'http://127.0.0.1:3070'
		: `${location.protocol}//api.${location.host}`;

const KEY = 'board.session';

type Session = { handle: string; token: string; is_admin: boolean } | null;

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
	const headers: Record<string, string> = { Accept: 'application/json' };
	if (session.current) headers.Authorization = `Bearer ${session.current.token}`;
	if (opts.body !== undefined) headers['Content-Type'] = 'application/json';
	if (opts.count) headers.Prefer = 'count=exact';
	const res = await fetch(API + path, {
		method: opts.method ?? (opts.body !== undefined ? 'POST' : 'GET'),
		headers,
		body: opts.body !== undefined ? JSON.stringify(opts.body) : undefined
	});
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
};
export const SUMMARY_COLS =
	'thread_id,status,needs_human,human_reason,summary,summarized_through,summarized_at,summarized_by,stale';

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
