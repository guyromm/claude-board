<script lang="ts">
	import { page } from '$app/state';
	import { mdTeaser } from '#lib/links.ts';
	import { goto } from '$app/navigation';
	import { api, ago, TASK_STATUSES, TASK_LABEL, type Task, type TaskStatus, type Agent, taskRef, taskHref } from '#lib/api.svelte.ts';
	import { every, REFRESH_MS } from '#lib/poll.ts';
	import { groupTree } from '#lib/tasktree.ts';

	// /tasks/<status>: the tasks in one status, one column per project (top-level task tree).
	// ?who=HANDLE narrows to one assignee, ?root=ID[,ID...] / ?not=ID[,ID...] show / hide project trees, as on /tasks.
	let tasks = $state<Task[]>([]);
	let agents = $state<Agent[]>([]);
	let error = $state('');

	const status = $derived(page.params.status as TaskStatus);
	const who = $derived(page.url.searchParams.get('who') ?? '');
	const ids = (k: string) => (page.url.searchParams.get(k) ?? '').split(',').map(Number).filter((n) => n > 0);
	const incl = $derived(ids('root'));
	const excl = $derived(ids('not'));

	// all tasks, cancelled included: a task's project is found through its ancestors, whatever their status
	const load = () =>
		api<Task[]>('/tasks?order=position,id')
			.then((r) => { tasks = r.data; error = ''; })
			.catch((e) => (error = e.message));
	$effect(() => { load(); return every(REFRESH_MS, load); });
	$effect(() => { api<Agent[]>('/agents?select=handle,kind,active&active=is.true&order=kind.desc,handle').then((r) => (agents = r.data)); });

	const byId = $derived(new Map(tasks.map((t) => [t.id, t])));
	const rootOf = (t: Task) => {
		let x = t;
		while (x.parent_id && byId.has(x.parent_id)) x = byId.get(x.parent_id)!;
		return x;
	};
	const path = (t: Task) => {
		const out: Task[] = [];
		for (let x = t.parent_id ? byId.get(t.parent_id) : undefined; x; x = x.parent_id ? byId.get(x.parent_id) : undefined) out.unshift(x);
		return out;
	};
	function under(t: Task, r: number): boolean {
		for (let x: Task | undefined = t; x; x = x.parent_id ? byId.get(x.parent_id) : undefined) if (x.id === r) return true;
		return false;
	}
	const inScope = (t: Task) => (!who || t.assignee === who) && (!incl.length || incl.some((r) => under(t, r))) && !excl.some((r) => under(t, r));
	const scopeLabel = $derived(
		[incl.length ? `only ${incl.map((id) => byId.get(id)?.title.split(/ \(|:/)[0].trim() ?? `#${id}`).join(', ')}` : '',
		 excl.length ? `except ${excl.map((id) => byId.get(id)?.title.split(/ \(|:/)[0].trim() ?? `#${id}`).join(', ')}` : ''].filter(Boolean).join(', '));
	// same colour per project as on /tasks
	const hue = (id: number) => Math.round((id * 137.508) % 360);
	const color = (id: number) => `hsl(${hue(id)} 65% 50%)`;

	const counts = $derived(
		Object.fromEntries([...TASK_STATUSES, 'cancelled'].map((s) => [s, tasks.filter((t) => t.status === s && inScope(t)).length]))
	);
	const projects = $derived.by(() => {
		const cols = new Map<number, { root: Task; items: Task[] }>();
		for (const t of tasks) {
			if (t.status !== status || !inScope(t)) continue;
			const r = rootOf(t);
			if (!cols.has(r.id)) cols.set(r.id, { root: r, items: [] });
			cols.get(r.id)!.items.push(t);
		}
		return [...cols.values()].sort((a, b) => b.items.length - a.items.length || a.root.id - b.root.id);
	});

	function setWho(v: string) {
		const q = new URLSearchParams(page.url.search);
		if (v) q.set('who', v); else q.delete('who');
		goto(`/tasks/${status}${q.size ? `?${q}` : ''}`);
	}
	// who / root / not carry over to the tabs and back to the board
	const qs = $derived.by(() => {
		const q = new URLSearchParams();
		for (const k of ['who', 'root', 'not']) { const v = page.url.searchParams.get(k); if (v) q.set(k, v); }
		return q.size ? `?${q}` : '';
	});
</script>

<div class="head">
	<h1><a href="/tasks{qs}">Tasks</a> <span class="muted">› {TASK_LABEL[status]}{#if scopeLabel}{' · '}{scopeLabel}{/if}</span></h1>
	<select value={who} onchange={(e) => setWho(e.currentTarget.value)}>
		<option value="">Everyone</option>
		{#each agents as a}<option value={a.handle}>{a.handle}</option>{/each}
	</select>
</div>
<nav class="tabs">
	{#each [...TASK_STATUSES, 'cancelled'] as s}
		<a href="/tasks/{s}{qs}" class:on={s === status}>{TASK_LABEL[s as TaskStatus]} <span class="muted">{counts[s] ?? 0}</span></a>
	{/each}
</nav>
{#if error}<p class="error">{error}</p>{/if}

{#if !projects.length && !error}
	<p class="muted">No tasks are {TASK_LABEL[status].toLowerCase()}{who ? ` for ${who}` : ''}.</p>
{/if}

<div class="board">
	{#each projects as p (p.root.id)}
		<section class="col" style="--proj: {color(p.root.id)}" aria-label="project #{p.root.id}">
			<h2><a href="/tasks?root={p.root.id}" title="this project on the board"><span class="sw"></span>#{p.root.id}/ {p.root.title}</a>
				<span class="muted">{p.items.length}</span></h2>
			{#each groupTree(p.items, byId) as { t, depth } (t.id)}
				<a class="card panel" class:sub={depth > 0} style="--depth: {depth}" href={taskHref(t)} class:human={t.needs_human}>
					{#if path(t).length > 1 && !depth}<div class="path muted">{path(t).slice(1).map((x) => x.title).join(' › ')}</div>{/if}
					<div class="title"><span class="muted">{taskRef(t)}</span> {t.title}</div>
					{#if t.needs_human}<div class="reason">Needs you: {mdTeaser(t.human_reason ?? '')}</div>{/if}
					<div class="meta">
						<span class="chip" class:none={!t.assignee}>{t.assignee ?? 'unassigned'}</span>
						{#if t.subtasks}<span class="muted" title="subtasks done">☑ {t.subtasks_done}/{t.subtasks}</span>{/if}
						{#if t.threads.length}<span class="muted" title="conversations">💬 {t.threads.length}</span>{/if}
						<span class="spacer"></span>
						<span class:late={t.overdue_checkin && status !== 'done'} class="muted" title="last activity">{ago(t.activity_at)}</span>
					</div>
					{#if t.last_note && status !== 'done'}<div class="note muted">{t.last_note}</div>{/if}
				</a>
			{/each}
		</section>
	{/each}
</div>

<style>
	.head { display: flex; gap: 0.6rem; align-items: center; flex-wrap: wrap; margin-bottom: 0.6rem; }
	.head h1 { margin: 0; flex: 1; min-width: 12rem; }
	.head h1 a { color: inherit; }
	.head select { width: auto; max-width: 16rem; }
	.tabs { display: flex; gap: 1rem; flex-wrap: wrap; margin-bottom: 1rem; font-size: 0.9rem; }
	.tabs a { color: var(--muted); padding: 0.2rem 0; border-bottom: 2px solid transparent; }
	.tabs a.on { color: var(--ink); border-bottom-color: var(--accent); text-decoration: none; }
	.board { display: grid; grid-auto-flow: column; grid-auto-columns: minmax(240px, 1fr); gap: 0.75rem; overflow-x: auto;
		padding-bottom: 1rem; align-items: start; }
	.col { background: color-mix(in srgb, var(--proj) 8%, transparent); border-top: 4px solid var(--proj); border-radius: 8px;
		padding: 0.5rem; display: flex; flex-direction: column; gap: 0.5rem; }
	.col h2 { font-size: 0.85rem; margin: 0.1rem 0.2rem; display: flex; gap: 0.4rem; align-items: baseline; }
	.col h2 a { color: var(--ink); flex: 1; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
	.sw { display: inline-block; width: 0.7rem; height: 0.7rem; border-radius: 2px; background: var(--proj); margin-right: 0.35rem; }
	.card { display: grid; gap: 0.3rem; padding: 0.55rem 0.65rem; color: var(--ink); font-size: 0.88rem;
		border-left: 4px solid var(--proj); background: color-mix(in srgb, var(--proj) 7%, var(--panel)); }
	.card:hover { text-decoration: none; border-color: var(--accent); }
	.card.human { border-color: #d9480f; box-shadow: 0 0 0 1px #d9480f; }
	.card.sub { margin-left: calc(var(--depth) * 0.9rem); margin-top: -0.25rem; }
	.path { font-size: 0.72rem; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
	.title { font-weight: 600; line-height: 1.3; }
	.reason { color: #d9480f; font-size: 0.78rem; font-weight: 500; display: -webkit-box; -webkit-line-clamp: 3; line-clamp: 3; -webkit-box-orient: vertical; overflow: hidden; }
	.meta { display: flex; gap: 0.5rem; align-items: center; font-size: 0.75rem; }
	.chip.none { background: transparent; border: 1px dashed var(--line); color: var(--muted); }
	.spacer { flex: 1; }
	.late { color: #d9480f; font-weight: 600; }
	.note { font-size: 0.75rem; display: -webkit-box; -webkit-line-clamp: 2; line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden; }
</style>
