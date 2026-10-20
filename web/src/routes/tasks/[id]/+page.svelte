<script lang="ts">
	import { page } from '$app/state';
	import { api, ago, fmtTime, TASK_STATUSES, TASK_LABEL, type Task, type TaskNote, type TaskThread, type Agent } from '#lib/api.svelte.ts';
	import { every, REFRESH_MS } from '#lib/poll.ts';
	import Body from '#lib/Body.svelte';

	const id = $derived(Number(page.params.id));
	let task = $state<Task | null>(null);
	let path = $state<Task[]>([]);
	let subs = $state<Task[]>([]);
	let notes = $state<TaskNote[]>([]);
	let threads = $state<TaskThread[]>([]);
	let agents = $state<Agent[]>([]);
	let error = $state('');
	let busy = $state(false);

	async function load() {
		try {
			const [t, s, n, th] = await Promise.all([
				api<Task[]>(`/tasks?id=eq.${id}`),
				api<Task[]>(`/tasks?parent_id=eq.${id}&order=position,id`),
				api<TaskNote[]>(`/task_notes?task_id=eq.${id}&order=id.desc`),
				api<TaskThread[]>(`/task_threads?task_id=eq.${id}&order=last_at.desc`)
			]);
			task = t.data[0] ?? null;
			if (!task) { error = `task #${id} not found`; return; }
			subs = s.data; notes = n.data; threads = th.data; error = '';
			const up: Task[] = [];
			for (let p = task.parent_id; p; ) {
				const r = await api<Task[]>(`/tasks?id=eq.${p}`);
				if (!r.data[0]) break;
				up.unshift(r.data[0]); p = r.data[0].parent_id;
			}
			path = up;
		} catch (e) { error = (e as Error).message; }
	}
	$effect(() => { void id; load(); return every(REFRESH_MS, load); });
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
</script>

{#if task}
	<div class="crumbs muted">
		<a href="/tasks">Tasks</a>
		{#each path as p} › <a href="/tasks/{p.id}">#{p.id} {p.title}</a>{/each}
		· <a href="/tasks?root={path[0]?.id ?? task.id}">board view</a>
	</div>
	<h1><span class="muted">#{task.id}</span> {task.title}</h1>

	{#if task.needs_human}
		<div class="attn"><b>Needs you:</b> {task.human_reason}
			<button class="link" disabled={busy} onclick={() => update({ needs_human: false })}>Clear</button></div>
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

	<section>
		<h2>Description <button class="link" onclick={() => { editing = !editing; desc = task?.description ?? ''; }}>{editing ? 'Cancel' : 'Edit'}</button></h2>
		{#if editing}
			<textarea bind:value={desc} rows="8"></textarea>
			<button disabled={busy} onclick={async () => { if (await update({ description: desc })) editing = false; }}>Save</button>
		{:else if task.description}<div class="desc"><Body text={task.description} /></div>
		{:else}<p class="muted">No description.</p>{/if}
	</section>

	<section>
		<h2>Subtasks <span class="muted">{task.subtasks_done}/{task.subtasks}</span></h2>
		{#each subs as s}
			<a class="sub" href="/tasks/{s.id}" class:done={s.status === 'done'} class:cancelled={s.status === 'cancelled'}>
				<span class="st {s.status}">{TASK_LABEL[s.status]}</span>
				<span><span class="muted">#{s.id}</span> {s.title}</span>
				<span class="chip">{s.assignee ?? 'unassigned'}</span>
				{#if s.needs_human}<span class="late">needs you</span>{/if}
				<span class="muted small">{ago(s.activity_at)}</span>
			</a>
		{/each}
		<form class="inline" onsubmit={async (e) => { e.preventDefault();
			if (await rpc('task_create', { title: sub.title, assignee: sub.assignee || null, parent: id })) sub = { title: '', assignee: '' }; }}>
			<input bind:value={sub.title} placeholder="New subtask" />
			<select bind:value={sub.assignee}>
				<option value="">unassigned</option>
				{#each agents as a}<option value={a.handle}>{a.handle}</option>{/each}
			</select>
			<button disabled={busy || !sub.title.trim()}>Add</button>
		</form>
	</section>

	<section>
		<h2>Conversations</h2>
		{#each threads as th}
			<div class="thread">
				<a href="/m/{th.thread_id}">#{th.thread_id} {th.subject}</a>
				<span class="muted small">{th.size} msgs · {ago(th.last_at)}{th.status ? ` · ${th.status}` : ''}</span>
				{#if th.needs_human}<span class="late small">needs you</span>{/if}
				<button class="link small" disabled={busy} onclick={() => rpc('task_link', { id, thread: th.thread_id, unlink: true })}>unlink</button>
				{#if th.summary}<div class="muted small">{th.summary}</div>{/if}
			</div>
		{:else}<p class="muted">None yet. Agents file them with <code>board post --task {id}</code> or <code>board task link {id} THREAD</code>.</p>{/each}
		<form class="inline" onsubmit={async (e) => { e.preventDefault();
			if (await rpc('task_link', { id, thread: Number(String(link).replace('#', '')) })) link = ''; }}>
			<input bind:value={link} placeholder="Thread or message #" />
			<button disabled={busy || !String(link).trim()}>Link</button>
		</form>
	</section>

	<section>
		<h2>Log</h2>
		<form class="note" onsubmit={async (e) => { e.preventDefault(); if (await update({ note })) note = ''; }}>
			<textarea bind:value={note} rows="2" placeholder="Add a note (progress, decision, instruction)…"></textarea>
			<button disabled={busy || !note.trim()}>Add note</button>
		</form>
		{#if !task.needs_human}
			<form class="inline" onsubmit={async (e) => { e.preventDefault();
				if (await update({ needs_human: true, human_reason: escalate })) escalate = ''; }}>
				<input bind:value={escalate} placeholder="Flag for the human: what must be decided or done" />
				<button class="ghost" disabled={busy || !escalate.trim()}>Flag</button>
			</form>
		{/if}
		{#each notes as n}
			<div class="entry">
				<div class="muted small"><b>{n.author}</b> · <span title={fmtTime(n.created_at)}>{ago(n.created_at)}</span>
					{#if n.change}<span class="change">{n.change}</span>{/if}</div>
				{#if n.body}<div class="body">{n.body}</div>{/if}
			</div>
		{/each}
	</section>
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
	.note { display: grid; gap: 0.4rem; justify-items: start; }
	.entry { padding: 0.5rem 0; border-bottom: 1px solid var(--line); }
	.change { margin-left: 0.4rem; font-family: var(--mono); font-size: 0.75rem; }
	code { font-size: 0.8rem; }
</style>
