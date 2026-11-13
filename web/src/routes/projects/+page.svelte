<script lang="ts">
	import { api, type ProjectInfo, type SystemInfo } from '#lib/api.svelte.ts';
	import { every, REFRESH_MS } from '#lib/poll.ts';

	// doc:systems-and-projects: projects (task nodes of kind 'project', nested: what for, with lead, clients and
	// the systems they use) and systems (what runs: owner, instances = the agents running it, the projects using it)
	let projects = $state<ProjectInfo[]>([]);
	let systems = $state<SystemInfo[]>([]);
	let error = $state('');
	let showClosed = $state(false);
	const load = () =>
		Promise.all([api<ProjectInfo[]>('/projects?order=path'), api<SystemInfo[]>('/system_catalog?order=slug')])
			.then(([p, s]) => { projects = p.data; systems = s.data; error = ''; })
			.catch((e) => (error = e.message));
	$effect(() => { load(); return every(REFRESH_MS, load); });

	const closed = (p: ProjectInfo) => p.status === 'done' || p.status === 'cancelled';
	// depth-first by parent project, siblings by path
	const tree = $derived.by(() => {
		const kids = new Map<number | null, ProjectInfo[]>();
		const ids = new Set(projects.map((p) => p.id));
		for (const p of projects) {
			const k = p.parent_project_id && ids.has(p.parent_project_id) ? p.parent_project_id : null;
			kids.set(k, [...(kids.get(k) ?? []), p]);
		}
		const out: { p: ProjectInfo; depth: number }[] = [];
		const walk = (k: number | null, depth: number) => {
			for (const p of (kids.get(k) ?? []).sort((a, b) => Number(closed(a)) - Number(closed(b)) || a.title.localeCompare(b.title))) {
				if (!closed(p) || showClosed) out.push({ p, depth });
				walk(p.id, depth + 1);
			}
		};
		walk(null, 0);
		return out;
	});
	const closedCount = $derived(projects.filter(closed).length);
	const ref = (p: { path: string; id: number }) => `#${p.path}${p.path.includes('/') ? '' : '/'}`;
	const clients = (p: ProjectInfo) => p.clients.map((c) => c.name + (c.for_name ? ` (for ${c.for_name})` : '')).join(', ');
</script>

<div class="head">
	<h1>Projects <span class="muted">{projects.length - closedCount}</span></h1>
	<a href="#systems">Systems ({systems.length})</a>
	<a class="muted" href="/docs/systems-and-projects">what these are</a>
	{#if closedCount}<label class="toggle"><input type="checkbox" bind:checked={showClosed} /> show {closedCount} closed</label>{/if}
</div>
{#if error}<p class="error">{error}</p>{/if}

<ul class="list">
	{#each tree as { p, depth } (p.id)}
		<li class="panel" class:closed={closed(p)} style="--depth: {depth}">
			<div class="row">
				<a class="title" href="/tasks?root={p.id}">{p.title.split(/ \(|:/)[0].trim()}</a>
				<a class="mono muted" href="/tasks/{p.path}">{ref(p)}</a>
				{#if p.status !== 'doing' && p.status !== 'ongoing'}<span class="chip sys">{p.status}</span>{/if}
				{#if p.needs_you}<a class="chip needs" href="/tasks?root={p.id}&needs=1">needs you {p.needs_you}</a>{/if}
				<span class="muted small">{p.open_tasks} open</span>
			</div>
			<div class="muted small meta">
				{#if p.lead}lead <a href="/agents#{p.lead}">{p.lead}</a>{:else}no lead{/if}
				{#if p.url} · <a href={p.url} target="_blank" rel="noopener">{p.url.replace(/^https?:\/\//, '')}</a>{/if}
				{#if p.clients.length} · client: <b>{clients(p)}</b>{#if p.clients.every((c) => c.inherited)} <span title="set on a parent project">(inherited)</span>{/if}{/if}
			</div>
			{#if p.systems.length}
				<div class="chips">{#each p.systems as s (s.system)}<a class="chip" href="#sys-{s.system}" title={s.role}>{s.system}</a>{/each}</div>
			{/if}
		</li>
	{/each}
</ul>

<h2 id="systems">Systems <span class="muted">{systems.length}</span></h2>
<ul class="list">
	{#each systems as s (s.slug)}
		<li class="panel" id="sys-{s.slug}">
			<div class="row">
				<b>{s.name}</b> <span class="mono muted">{s.slug}</span> <span class="chip sys">{s.kind}</span>
				{#if s.open_tasks}<a class="muted small" href="/tasks">{s.open_tasks} open system tasks</a>{/if}
			</div>
			{#if s.description}<div class="small">{s.description}</div>{/if}
			<div class="muted small meta">
				owner {s.owner ?? '—'}
				{#if s.instances.length > 1 || (s.instances[0] && s.instances[0].agent !== s.owner)}
					· run by {#each s.instances as i, n (i.agent)}{n ? ', ' : ''}<span class="mono">{i.agent}</span>{#if i.label} ({i.label}){:else if i.host} ({i.host}){/if}{/each}
				{:else if s.instances[0]?.host} · on {s.instances[0].host}{/if}
			</div>
			{#if s.projects.length}
				<div class="chips">used by {#each s.projects as p (p.id)}<a class="chip" href="/tasks?root={p.id}">{p.slug ?? p.title}</a>{/each}</div>
			{/if}
		</li>
	{/each}
</ul>

<style>
	.head { display: flex; gap: 1rem; align-items: baseline; flex-wrap: wrap; margin-bottom: 1rem; }
	.head h1 { margin: 0; }
	.toggle { display: inline-flex; gap: 0.3rem; align-items: center; margin: 0; font-size: 0.85rem; }
	h2 { margin: 1.5rem 0 0.75rem; scroll-margin-top: 4rem; }
	.list { list-style: none; padding: 0; margin: 0; display: grid; gap: 0.5rem; }
	.list li { padding: 0.6rem 0.9rem; display: grid; gap: 0.25rem; scroll-margin-top: 4rem; }
	.list li[style] { margin-left: calc(var(--depth) * 1.5rem); }
	.list li.closed { opacity: 0.6; }
	.row { display: flex; gap: 0.5rem; align-items: baseline; flex-wrap: wrap; }
	.title { font-weight: 600; }
	.small { font-size: 0.8rem; }
	.meta { display: flex; gap: 0.3rem; flex-wrap: wrap; }
	.chips { display: flex; gap: 0.3rem; flex-wrap: wrap; align-items: baseline; font-size: 0.8rem; color: var(--muted); }
	.chip.needs { color: #b45309; border-color: currentColor; }
	@media (max-width: 600px) { .list li[style] { margin-left: calc(var(--depth) * 0.75rem); } }
</style>
