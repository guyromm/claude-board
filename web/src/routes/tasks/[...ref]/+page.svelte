<script lang="ts">
	import { page } from '$app/state';
	import { api, ago, fmtTime, taskRef, taskHref, TASK_STATUSES, TASK_LABEL, type Task, type TaskNote, type TaskThread, type TaskEscalation, type Agent } from '#lib/api.svelte.ts';
	import { every, REFRESH_MS } from '#lib/poll.ts';
	import { head } from '#lib/title.svelte.ts';
	import Body from '#lib/Body.svelte';
	import Md from '#lib/Md.svelte';

	// /tasks/151 (the id) or /tasks/119/3 (the semantic path; old paths of moved tasks resolve too)
	const ref = $derived(page.params.ref ?? '');
	let id = $state(0);
	$effect(() => {
		const r = ref.replace(/\/+$/, '');
		if (/^\d+$/.test(r)) { id = Number(r); return; }
		api<string>('/rpc/task_id', { body: { ref: r } }).then((x) => (id = Number(x.data))).catch((e) => (error = (e as Error).message));
	});
	let task = $state<Task | null>(null);
	$effect(() => { if (task) head.title = `${taskRef(task)} ${task.title}`; });
	let path = $state<Task[]>([]);
	let subs = $state<Task[]>([]);
	let notes = $state<TaskNote[]>([]);
	let threads = $state<TaskThread[]>([]);
	let escs = $state<TaskEscalation[]>([]);
	let agents = $state<Agent[]>([]);
	let error = $state('');
	let busy = $state(false);

	async function load() {
		try {
			const [t, s, n, th, es] = await Promise.all([
				api<Task[]>(`/tasks?id=eq.${id}`),
				api<Task[]>(`/tasks?parent_id=eq.${id}&order=position,id`),
				api<TaskNote[]>(`/task_notes?task_id=eq.${id}&order=id.desc`),
				api<TaskThread[]>(`/task_threads?task_id=eq.${id}&order=last_at.desc`),
				api<TaskEscalation[]>(`/task_escalations?task_id=eq.${id}&order=id.desc`)
			]);
			task = t.data[0] ?? null;
			if (!task) { error = `task #${id} not found`; return; }
			subs = s.data; notes = n.data; threads = th.data; escs = es.data; error = '';
			const up: Task[] = [];
			for (let p = task.parent_id; p; ) {
				const r = await api<Task[]>(`/tasks?id=eq.${p}`);
				if (!r.data[0]) break;
				up.unshift(r.data[0]); p = r.data[0].parent_id;
			}
			path = up;
		} catch (e) { error = (e as Error).message; }
	}
	$effect(() => { if (!id) return; void id; load(); return every(REFRESH_MS, load); });
	$effect(() => { api<Agent[]>('/agents?select=handle,kind&active=is.true&order=kind.desc,handle').then((r) => (agents = r.data)); });

	async function rpc(fn: string, body: object) {
		busy = true; error = '';
		try { await api(`/rpc/${fn}`, { body }); await load(); return true; }
		catch (e) { error = (e as Error).message; return false; }
		finally { busy = false; }
	}
	const update = (fields: object) => rpc('task_update', { id, ...fields });

	let note = $state('');
	let escalate = $state('');
	let link = $state('');
	let sub = $state({ title: '', assignee: '' });
	let editing = $state(false);
	let desc = $state('');

	// the escalation that last ended (answered or cleared; a re-worded one was replaced, not ended)
	const lastEnded = $derived(escs.find((e) => e.outcome === 'answered' || e.outcome === 'cleared'));
	const OUTCOME: Record<TaskEscalation['outcome'], string> = { open: 'needs you now', answered: 'answered', cleared: 'cleared', reworded: 'reworded' };

	// the timeline: log entries plus subtasks created and conversations filed under this task, newest first
	type Ev = { at: string; key: string; author: string; kind: 'note' | 'sub' | 'link'; esc?: boolean;
		note?: TaskNote; sub?: Task; th?: TaskThread };
	let logFilter = $state<'all' | 'notes' | 'escalations' | 'changes'>('all');
	const timeline = $derived.by(() => {
		const ev: Ev[] = notes.map((n) => ({ at: n.created_at, key: `n${n.id}`, author: n.author, kind: 'note' as const, note: n,
			esc: /escalat/.test(n.change ?? '') }));
		for (const s of subs) ev.push({ at: s.created_at, key: `s${s.id}`, author: s.created_by, kind: 'sub', sub: s });
		for (const th of threads) ev.push({ at: th.linked_at, key: `t${th.thread_id}`, author: th.linked_by, kind: 'link', th });
		ev.sort((a, b) => b.at.localeCompare(a.at));
		return ev.filter((e) => logFilter === 'all' || (logFilter === 'escalations' ? e.esc
			: logFilter === 'notes' ? e.kind === 'note' && !!e.note?.body : e.kind !== 'note' || !!e.note?.change));
	});
</script>

{#if task}
	<div class="crumbs muted">
		<a href="/tasks">Tasks</a>
		{#each path as p} › <a href={taskHref(p)}>{taskRef(p)} {p.title}</a>{/each}
		· <a href="/tasks?root={path[0]?.id ?? task.id}">board view</a>
	</div>
	<h1><span class="muted" title="id {task.id}">{taskRef(task)}</span> {task.title}</h1>

	{#if task.needs_human}
		<div class="attn"><b>Needs you</b>
			<button class="link" disabled={busy} onclick={() => update({ needs_human: false })}>Clear</button>
			<div class="need"><Md text={task.human_reason ?? ''} /></div></div>
	{:else if lastEnded}
		<!-- the last "needs you", kept in view after an answer cleared it -->
		<details class="was">
			<summary><b>Last needs-you</b> <span class="muted">· {OUTCOME[lastEnded.outcome]} by {lastEnded.ended_by}
				<span title={fmtTime(lastEnded.ended_at ?? '')}>{ago(lastEnded.ended_at ?? '')}</span></span>
				{#if lastEnded.answer}<span class="ans"><b>{lastEnded.ended_by}:</b> <Body text={lastEnded.answer} inline /></span>{/if}</summary>
			<div class="why"><Md text={lastEnded.reason} /></div>
			<div class="muted small">raised by {lastEnded.raised_by} <span title={fmtTime(lastEnded.raised_at)}>{ago(lastEnded.raised_at)}</span>
				· <a href="#escalations">all escalations ({escs.length})</a></div>
		</details>
	{/if}

	<div class="fields panel">
		<label>Status
			<select value={task.status} disabled={busy} onchange={(e) => update({ status: e.currentTarget.value })}>
				{#each [...TASK_STATUSES, 'cancelled' as const] as s}<option value={s}>{TASK_LABEL[s]}</option>{/each}
			</select>
		</label>
		<label>Assignee (responsible)
			<select value={task.assignee ?? '-'} disabled={busy} onchange={(e) => update({ assignee: e.currentTarget.value })}>
				<option value="-">unassigned</option>
				{#each agents as a}<option value={a.handle}>{a.handle}</option>{/each}
			</select>
		</label>
		<label>PM check-in after no activity for
			<input value={task.check_every} disabled={busy} onchange={(e) => update({ check_every: e.currentTarget.value })} />
		</label>
		<div class="facts muted">
			created {ago(task.created_at)} by {task.created_by} · last activity {ago(task.activity_at)}
			{#if task.overdue_checkin && task.status !== 'done'}<b class="late">· check-in overdue</b>{/if}
			{#if task.pm_prompted_at}· PM last checked {ago(task.pm_prompted_at)}{/if}
		</div>
	</div>
	{#if error}<p class="error">{error}</p>{/if}

	<!-- actions sit above the description: the sections below can be long -->
	<section class="actions panel">
		<nav class="small"><a href="#subtasks">Subtasks ({task.subtasks})</a> · <a href="#conversations">Conversations ({threads.length})</a> · <a href="#log">Log ({notes.length})</a>{#if escs.length} · <a href="#escalations">Escalations ({escs.length})</a>{/if}</nav>
		<form class="note" onsubmit={async (e) => { e.preventDefault(); if (await update({ note })) note = ''; }}>
			<textarea bind:value={note} rows="2" placeholder="Add a note (progress, decision, instruction)…"></textarea>
			<button disabled={busy || !note.trim()}>Add note</button>
		</form>
		<form class="inline" onsubmit={async (e) => { e.preventDefault();
			if (await rpc('task_create', { title: sub.title, assignee: sub.assignee || null, parent: id })) sub = { title: '', assignee: '' }; }}>
			<input bind:value={sub.title} placeholder="New subtask" />
			<select bind:value={sub.assignee}>
				<option value="">unassigned</option>
				{#each agents as a}<option value={a.handle}>{a.handle}</option>{/each}
			</select>
			<button disabled={busy || !sub.title.trim()}>Add</button>
		</form>
		<form class="inline" onsubmit={async (e) => { e.preventDefault();
			if (await rpc('task_link', { id, thread: Number(String(link).replace('#', '')) })) link = ''; }}>
			<input bind:value={link} placeholder="Thread or message #" />
			<button disabled={busy || !String(link).trim()}>Link</button>
		</form>
		{#if !task.needs_human}
			<form class="inline" onsubmit={async (e) => { e.preventDefault();
				if (await update({ needs_human: true, human_reason: escalate })) escalate = ''; }}>
				<input bind:value={escalate} placeholder="Flag for the human: what must be decided or done" />
				<button class="ghost" disabled={busy || !escalate.trim()}>Flag</button>
			</form>
		{/if}
	</section>

	<section>
		<h2>Description <button class="link" onclick={() => { editing = !editing; desc = task?.description ?? ''; }}>{editing ? 'Cancel' : 'Edit'}</button></h2>
		{#if editing}
			<textarea bind:value={desc} rows="8"></textarea>
			<button disabled={busy} onclick={async () => { if (await update({ description: desc })) editing = false; }}>Save</button>
		{:else if task.description}<div class="desc"><Body text={task.description} /></div>
		{:else}<p class="muted">No description.</p>{/if}
	</section>

	<section id="subtasks">
		<h2>Subtasks <span class="muted">{task.subtasks_done}/{task.subtasks}</span></h2>
		{#each subs as s}
			<a class="sub" href={taskHref(s)} class:done={s.status === 'done'} class:cancelled={s.status === 'cancelled'}>
				<span class="st {s.status}">{TASK_LABEL[s.status]}</span>
				<span><span class="muted">{taskRef(s)}</span> {s.title}</span>
				<span class="chip">{s.assignee ?? 'unassigned'}</span>
				{#if s.needs_human}<span class="late">needs you</span>{/if}
				<span class="muted small">{ago(s.activity_at)}</span>
			</a>
		{/each}
	</section>

	<section id="conversations">
		<h2>Conversations</h2>
		{#each threads as th}
			<div class="thread">
				<a href="/m/{th.thread_id}">#{th.thread_id} {th.subject}</a>
				<span class="muted small">{th.size} msgs · {ago(th.last_at)}{th.status ? ` · ${th.status}` : ''}</span>
				{#if th.needs_human}<span class="late small">needs you</span>{/if}
				<button class="link small" disabled={busy} onclick={() => rpc('task_link', { id, thread: th.thread_id, unlink: true })}>unlink</button>
				{#if th.summary}<div class="muted small"><Body text={th.summary} inline /></div>{/if}
			</div>
		{:else}<p class="muted">None yet. Agents file them with <code>board post --task {id}</code> or <code>board task link {id} THREAD</code>.</p>{/each}
	</section>

	<section id="log">
		<h2>Log
			<span class="filters small">
				{#each [['all', 'All'], ['notes', 'Notes'], ['changes', 'Changes'], ['escalations', 'Escalations']] as [k, label]}
					<button class="link" class:on={logFilter === k} onclick={() => (logFilter = k as typeof logFilter)}>{label}</button>
				{/each}
			</span>
		</h2>
		{#each timeline as e (e.key)}
			<div class="entry" class:esc={e.esc}>
				<div class="muted small"><b>{e.author}</b> · <span title={fmtTime(e.at)}>{ago(e.at)}</span>
					{#if e.note?.change}<span class="change"><Body text={e.note.change} inline /></span>
					{:else if e.sub}<span class="change">created subtask <a href="/tasks/{e.sub.id}">#{e.sub.id} {e.sub.title}</a>{e.sub.assignee ? ` @${e.sub.assignee}` : ''}</span>
					{:else if e.th}<span class="change">filed conversation <a href="/m/{e.th.thread_id}">#{e.th.thread_id} {e.th.subject}</a></span>{/if}</div>
				{#if e.note?.body}<div class="body"><Body text={e.note.body} inline /></div>{/if}
			</div>
		{:else}<p class="muted">Nothing in this view.</p>{/each}
	</section>

	{#if escs.length}
		<section id="escalations">
			<h2>Escalations <span class="muted">{escs.length}</span></h2>
			{#each escs as e (e.id)}
				<details class="escrow {e.outcome}" open={e.outcome === 'open' || e.id === lastEnded?.id}>
					<summary class="small"><span class="oc">{OUTCOME[e.outcome]}</span>
						raised by <b>{e.raised_by}</b> <span title={fmtTime(e.raised_at)}>{ago(e.raised_at)}</span>
						{#if e.ended_at}<span class="muted">· {e.outcome} by {e.ended_by} {ago(e.ended_at)}</span>{/if}</summary>
					<div class="why"><Md text={e.reason} /></div>
					{#if e.answer}<div class="ans"><b>{e.ended_by}:</b> <Body text={e.answer} inline /></div>{/if}
				</details>
			{/each}
		</section>
	{/if}
{:else if error}
	<p class="error">{error}</p>
{:else}
	<p class="muted">Loading…</p>
{/if}

<style>
	.crumbs { font-size: 0.85rem; margin-bottom: 0.3rem; }
	h1 { margin-bottom: 0.8rem; }
	h2 { font-size: 0.95rem; margin: 0 0 0.5rem; display: flex; gap: 0.6rem; align-items: baseline; }
	section { margin-top: 1.4rem; }
	.attn { background: color-mix(in srgb, #d9480f 10%, var(--panel)); border-left: 4px solid #d9480f; padding: 0.5rem 0.75rem;
		border-radius: 6px; margin-bottom: 1rem; display: flex; gap: 0.75rem; align-items: baseline; flex-wrap: wrap; }
	.fields { display: grid; grid-template-columns: repeat(auto-fill, minmax(200px, 1fr)); gap: 0.7rem; padding: 0.8rem; }
	.fields label { margin: 0; }
	.facts { grid-column: 1 / -1; font-size: 0.8rem; }
	.late { color: #d9480f; font-weight: 600; }
	.desc, .body { white-space: pre-wrap; overflow-wrap: anywhere; font-size: 0.92rem; }
	.sub { display: flex; gap: 0.6rem; align-items: center; padding: 0.35rem 0; border-bottom: 1px solid var(--line); color: var(--ink); flex-wrap: wrap; }
	.sub.done { opacity: 0.65; }
	.sub.cancelled { opacity: 0.4; text-decoration: line-through; }
	.st { font-size: 0.7rem; text-transform: uppercase; letter-spacing: 0.05em; font-weight: 700; min-width: 4.5rem; color: var(--muted); }
	.st.doing { color: var(--accent); }
	.st.blocked { color: #d9480f; }
	.st.done { color: #2e9d5b; }
	.small { font-size: 0.78rem; }
	.inline { display: flex; gap: 0.5rem; margin-top: 0.5rem; flex-wrap: wrap; }
	.inline input { flex: 1; min-width: 12rem; }
	.inline select { width: auto; }
	.thread { padding: 0.35rem 0; border-bottom: 1px solid var(--line); display: flex; gap: 0.5rem; align-items: baseline; flex-wrap: wrap; }
	.thread > div { flex-basis: 100%; }
	.actions { padding: 0.8rem; }
	.actions nav { margin-bottom: 0.5rem; }
	.note { display: grid; gap: 0.4rem; justify-items: start; }
	.entry { padding: 0.5rem 0; border-bottom: 1px solid var(--line); }
	.change { margin-left: 0.4rem; font-family: var(--mono); font-size: 0.75rem; }
	.entry.esc { border-left: 3px solid #d9480f; padding-left: 0.5rem; }
	.filters { margin-left: auto; display: flex; gap: 0.6rem; font-weight: 400; }
	.filters .on { font-weight: 700; text-decoration: underline; }
	.was { background: color-mix(in srgb, var(--line) 30%, var(--panel)); border-left: 4px solid var(--muted); padding: 0.5rem 0.75rem;
		border-radius: 6px; margin-bottom: 1rem; font-size: 0.9rem; }
	.was summary { cursor: pointer; }
	.why { margin: 0.4rem 0; }
	.need { flex-basis: 100%; }
	.ans { display: block; margin-top: 0.3rem; white-space: pre-wrap; }
	.escrow { padding: 0.4rem 0; border-bottom: 1px solid var(--line); }
	.escrow summary { cursor: pointer; }
	.escrow .oc { display: inline-block; min-width: 6.5rem; font-weight: 700; text-transform: uppercase; font-size: 0.7rem; letter-spacing: 0.05em; color: var(--muted); }
	.escrow.open .oc { color: #d9480f; }
	.escrow.answered .oc { color: #2e9d5b; }
	code { font-size: 0.8rem; }
</style>
