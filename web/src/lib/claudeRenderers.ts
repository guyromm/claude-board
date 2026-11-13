// claude-ui rendering plug-ins for the board (ClaudePage/ClaudeDock `renderers`): in the chat, "#119/3" and
// "#119/" link to the task and "#1456" to the message, as in board text (links.ts). Hovering one shows its
// title, state and assignee, and whether it needs you (the escalation's first paragraph). The data is
// fetched in batches as references render, and again on hover once it is a minute old.
import { api } from '#lib/api.svelte.ts';
import { mdTeaser } from '#lib/links.ts';

type TaskInfo = { path: string; parent_id: number | null; title: string; status: string; assignee: string | null;
	needs_human: boolean; human_reason: string | null };
type MsgInfo = { id: number; thread_id: number; subject: string; sender: string };
type ThreadInfo = { thread_id: number; subject: string; status: string | null; needs_human: boolean; human_reason: string | null };
type Info = { tip: string; needs: boolean; closed: boolean };

const TTL = 60_000;
const cache = new Map<string, { at: number; info: Info | null }>(); // key: "t:119/3" | "m:1456"
const els = new Map<string, Set<HTMLElement>>();
let queued = new Set<string>();
let timer: ReturnType<typeof setTimeout> | null = null;

const clip = (s: string, n = 300) => (s.length > n ? s.slice(0, n - 1) + '…' : s);
const list = (xs: string[]) => `(${xs.map((x) => `"${x}"`).join(',')})`;

function paint(key: string) {
	const c = cache.get(key);
	for (const a of els.get(key) ?? []) {
		if (!a.isConnected) { els.get(key)!.delete(a); continue; }
		a.title = c?.info ? c.info.tip : `${a.textContent}: not found`;
		a.classList.toggle('cui-needs', !!c?.info?.needs);
		a.classList.toggle('cui-closed', !!c?.info?.closed);
	}
}

async function flush() {
	timer = null;
	const keys = [...queued];
	queued = new Set();
	const tasks = keys.filter((k) => k.startsWith('t:')).map((k) => k.slice(2));
	const msgs = keys.filter((k) => k.startsWith('m:')).map((k) => k.slice(2));
	const now = Date.now();
	if (tasks.length) {
		try {
			const r = await api<TaskInfo[]>(`/tasks?select=path,parent_id,title,status,assignee,needs_human,human_reason&path=in.${encodeURIComponent(list(tasks))}`);
			const got = new Map(r.data.map((t) => [t.path, t]));
			for (const p of tasks) {
				const t = got.get(p);
				cache.set(`t:${p}`, { at: now, info: t ? {
					tip: `#${t.path}${t.parent_id ? '' : '/'} ${t.title}\n${t.status} · @${t.assignee ?? 'unassigned'}` +
						(t.needs_human ? `\nNEEDS YOU: ${clip(mdTeaser(t.human_reason ?? ''))}` : ''),
					needs: t.needs_human, closed: t.status === 'done' || t.status === 'cancelled' } : null });
				paint(`t:${p}`);
			}
		} catch { /* leave the links plain; the next render or hover retries */ }
	}
	if (msgs.length) {
		try {
			const m = await api<MsgInfo[]>(`/messages?select=id,thread_id,subject,sender&id=in.(${msgs.join(',')})`);
			const tids = [...new Set(m.data.map((x) => x.thread_id))];
			const th = tids.length
				? (await api<ThreadInfo[]>(`/threads?select=thread_id,subject,status,needs_human,human_reason&thread_id=in.(${tids.join(',')})`)).data
				: [];
			const byM = new Map(m.data.map((x) => [String(x.id), x]));
			const byT = new Map(th.map((x) => [x.thread_id, x]));
			for (const id of msgs) {
				const x = byM.get(id), t = x && byT.get(x.thread_id);
				cache.set(`m:${id}`, { at: now, info: x ? {
					tip: `#${id} from ${x.sender}: ${x.subject}` + (x.thread_id !== x.id ? `\nin thread #${x.thread_id} "${t?.subject ?? ''}"` : '') +
						(t ? `\nthread ${t.status ?? 'not summarized'}` : '') +
						(t?.needs_human ? `\nNEEDS YOU: ${clip(mdTeaser(t.human_reason ?? ''))}` : ''),
					needs: !!t?.needs_human, closed: t?.status === 'closed' } : null });
				paint(`m:${id}`);
			}
		} catch { /* as above */ }
	}
}

function want(key: string, a: HTMLElement) {
	if (!els.has(key)) els.set(key, new Set());
	els.get(key)!.add(a);
	const c = cache.get(key);
	if (c) paint(key);
	if (!c || Date.now() - c.at > TTL) {
		queued.add(key);
		timer ??= setTimeout(flush, 50);
	}
}

function link(text: string, href: string, key: string): HTMLElement {
	const a = document.createElement('a');
	a.textContent = text;
	a.href = href;
	a.className = 'cui-ref';
	a.addEventListener('mouseenter', () => want(key, a));
	want(key, a);
	return a;
}

export const boardRenderers = [
	// tasks first: "#119/3" or "#119/" (a top-level task); the same pattern as links.ts
	{ pattern: /(?<![\w&])#(\d+(?:\/\d+)+|\d+\/)(?![\w#/])/g,
	  render: (m: RegExpExecArray) => { const p = m[1].replace(/\/$/, ''); return link(m[0], `/tasks/${p}`, `t:${p}`); } },
	// bare "#1456": a message (thread)
	{ pattern: /(?<![\w&])#(\d+)\b(?!\/)/g,
	  render: (m: RegExpExecArray) => link(m[0], `/m/${m[1]}`, `m:${m[1]}`) }
];
