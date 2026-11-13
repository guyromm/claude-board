<script lang="ts">
	import { page } from '$app/state';
	import { goto } from '$app/navigation';
	import { api, ago, TASK_STATUSES, TASK_LABEL, HUMAN_LEVEL, type Task, type TaskStatus, type TaskEscalation, type Agent, type SystemInfo, taskRef, taskHref } from '#lib/api.svelte.ts';
	import { every, REFRESH_MS } from '#lib/poll.ts';
	import { groupTree } from '#lib/tasktree.ts';
	import Body from '#lib/Body.svelte';
	import Md from '#lib/Md.svelte';
	import { mdTeaser } from '#lib/links.ts';

	// Kanban over board.task: one column per status. ?root=ID[,ID...] narrows to those tasks and everything under
	// them, ?not=ID[,ID...] hides those trees (e.g. "all projects except pethelp": ?not=1), ?who=HANDLE narrows to
	// one assignee. Cards are dragged between columns (and reordered within one).
	let tasks = $state<Task[]>([]);
	let agents = $state<Agent[]>([]);
	let error = $state('');
	let busy = $state(false);

	const ids = (k: string) => (page.url.searchParams.get(k) ?? '').split(',').map(Number).filter((n) => n > 0);
	const incl = $derived(ids('root'));
	const excl = $derived(ids('not'));
	// exactly one project picked: the heading names it and new tasks go under it
	const root = $derived(incl.length === 1 ? incl[0] : null);
	const who = $derived(page.url.searchParams.get('who') ?? '');
	let projOpen = $state(false);

	// escalations that ended (answered or cleared) in the last 7 days: "Needs you" items that were just answered
	let ended = $state<TaskEscalation[]>([]);
	const load = () =>
		Promise.all([
			api<Task[]>('/tasks?status=neq.cancelled&order=position,id'),
			api<TaskEscalation[]>(`/task_escalations?outcome=in.(answered,cleared)&ended_at=gte.${new Date(Date.now() - 7 * 864e5).toISOString()}&order=ended_at.desc`)
		])
			.then(([r, e]) => { tasks = r.data; ended = e.data; error = ''; })
			.catch((e) => (error = e.message));
	$effect(() => { load(); return every(REFRESH_MS, load); });
	$effect(() => { api<Agent[]>('/agents?select=handle,kind,active&active=is.true&order=kind.desc,handle').then((r) => (agents = r.data)); });
	// the system catalog: which systems each agent runs and which projects use them (labels umbrella subtasks)
	let systems = $state<SystemInfo[]>([]);
	$effect(() => { api<SystemInfo[]>('/system_catalog?select=slug,owner,instances,projects&order=slug').then((r) => (systems = r.data)).catch(() => {}); });

	const byId = $derived(new Map(tasks.map((t) => [t.id, t])));
	const roots = $derived(tasks.filter((t) => t.parent_id === null || !byId.has(t.parent_id)));
	function under(t: Task, r: number): boolean {
		for (let x: Task | undefined = t; x; x = x.parent_id ? byId.get(x.parent_id) : undefined) if (x.id === r) return true;
		return false;
	}
	const path = (t: Task) => {
		const out: Task[] = [];
		for (let x = t.parent_id ? byId.get(t.parent_id) : undefined; x; x = x.parent_id ? byId.get(x.parent_id) : undefined) out.unshift(x);
		return out;
	};
	// each project (top-level task tree) gets its own hue, stable per root id (golden-angle spacing)
	const rootOf = (t: Task) => {
		let x = t;
		while (x.parent_id && byId.has(x.parent_id)) x = byId.get(x.parent_id)!;
		return x;
	};
	const hue = (id: number) => Math.round((id * 137.508) % 360);
	// under an umbrella task (#119/ daily commit review: one subtask per project) a task belongs to its
	// assignee's project, so it is named and coloured after the assignee instead of the umbrella
	const viaOwner = (t: Task) => rootOf(t).umbrella && rootOf(t).id !== t.id && !!t.assignee;
	const nameHue = (s: string) => [...s].reduce((h, c) => (h * 31 + c.charCodeAt(0)) % 360, 7);
	// what a task is for (doc:systems-and-projects): its nearest project node; else the system it (or an
	// ancestor) names: system work; else Operations (backups, check-ups), named after its top-level task.
	// An umbrella's subtasks (#119/ commit reviews, one per agent) go with their ASSIGNEE's work (guy 11-10): if a
	// system the agent runs serves exactly one open project (ofana-app -> ofana), that project; else the agent's
	// system, which serves several (classifier, scraper-engine: its commits touch many projects); else its handle.
	type Label = { group: 0 | 1 | 2; name: string; hue: number };
	const GROUP = ['Projects', 'Systems', 'Operations'] as const;
	const systemOf = (t: Task) => {
		for (let x: Task | undefined = t; x; x = x.parent_id ? byId.get(x.parent_id) : undefined) if (x.system) return x.system;
		return null;
	};
	const labelOf = (t: Task): Label => {
		const p = t.project_id ? byId.get(t.project_id) : undefined;
		if (p) return { group: 0, name: p.slug ?? p.title.split(/ \(|:/)[0].trim(), hue: hue(p.id) };
		if (viaOwner(t)) {
			const a = t.assignee!;
			const mine = systems.filter((s) => s.owner === a || s.instances.some((i) => i.agent === a))
				.sort((x, y) => Number(y.owner === a) - Number(x.owner === a));
			const open = (id: number) => { const p = byId.get(id); return !!p && p.status !== 'done' && p.status !== 'cancelled'; };
			for (const s of mine) {
				const ps = s.projects.filter((p) => open(p.id));
				if (ps.length === 1) { const p = byId.get(ps[0].id)!; return { group: 0, name: p.slug ?? p.title.split(/ \(|:/)[0].trim(), hue: hue(p.id) }; }
			}
			const sys = mine[0]?.slug ?? t.assignee_system;
			if (sys) return { group: 1, name: sys, hue: nameHue(sys) };
			return { group: 2, name: a, hue: nameHue(a) };
		}
		const sys = systemOf(t);
		if (sys) return { group: 1, name: sys, hue: nameHue(sys) };
		const r = rootOf(t);
		return { group: 2, name: r.title.split(/ \(|:|,/)[0].trim(), hue: hue(r.id) };
	};
	const projColor = (t: Task) => `hsl(${labelOf(t).hue} 65% 50%)`;
	const projName = (t: Task) => labelOf(t).name;
	const inScope = (t: Task) => (!incl.length || incl.some((r) => under(t, r))) && !excl.some((r) => under(t, r));
	const shown = $derived(tasks.filter((t) => inScope(t) && (!who || t.assignee === who)));
	const shortName = (r: Task) => r.title.split(/ \(|:/)[0].trim();
	const projLabel = $derived(
		incl.length > 1 ? `${incl.length} projects${excl.length ? `, ${excl.length} hidden` : ''}`
		: !incl.length && excl.length ? `All except ${excl.map((id) => (byId.get(id) ? shortName(byId.get(id)!) : `#${id}`)).join(', ')}`
		: '');
	const column = (s: TaskStatus) => shown.filter((t) => t.status === s);
	// urgent first, then soon, then whenever (the PM's or the human's rating, api.task_urgency); within a level projects
	// first, then systems, then operations; first-seen order within each
	const lvl = (t: Task) => t.human_level ?? 2;
	const attention = $derived(shown.filter((t) => t.needs_human).map((t, i) => ({ t, i, g: labelOf(t).group }))
		.sort((a, b) => lvl(a.t) - lvl(b.t) || a.g - b.g || a.i - b.i).map((x) => x.t));
	const levelCounts = $derived([1, 2, 3].map((l) => attention.filter((t) => lvl(t) === l).length));
	async function rate(t: Task, level: number) {
		busy = true;
		try { await api('/rpc/task_urgency', { body: { id: t.id, level: String(level) } }); await load(); }
		catch (e) { error = (e as Error).message; }
		finally { busy = false; }
	}
	// the latest ended escalation per task in view, unless the task needs the human again
	const answered = $derived.by(() => {
		const seen = new Set<number>(), out: TaskEscalation[] = [];
		for (const e of ended) {
			const t = byId.get(e.task_id);
			if (seen.has(e.task_id) || !t || t.needs_human || !shown.includes(t)) continue;
			seen.add(e.task_id); out.push(e);
		}
		return out;
	});
	const answeredOpen = $derived(page.url.searchParams.get('answered') === '1');
	// folded "Needs you": per level, the task numbers grouped by project, in first-seen order
	const attnByLevel = $derived([1, 2, 3].map((l) => {
		const m = new Map<string, Task[]>();
		for (const t of attention) if (lvl(t) === l) m.set(projName(t), [...(m.get(projName(t)) ?? []), t]);
		return [l, [...m]] as const;
	}).filter(([, ps]) => ps.length));
	// a level heading ("Urgent") before the first item of each level, a group heading ("Systems") before each group in it
	const levelStart = (list: Task[], i: number) => i === 0 || lvl(list[i - 1]) !== lvl(list[i]);
	const groupStart = (list: Task[], i: number) => levelStart(list, i) || labelOf(list[i - 1]).group !== labelOf(list[i]).group;

	function setParams(kv: Record<string, string>, opts: { replace?: boolean; reset?: boolean } = {}) {
		const q = new URLSearchParams(page.url.search);
		for (const [k, v] of Object.entries(kv)) if (v) q.set(k, v); else q.delete(k);
		goto(`/tasks${q.size ? `?${q}` : ''}`, opts);
	}
	const setParam = (k: string, v: string, opts: { replace?: boolean; reset?: boolean } = {}) => setParams({ [k]: v }, opts);
	// project menu: a click cycles a project neutral -> shown (only the shown ones) -> hidden -> neutral
	function cycle(id: number) {
		const i = incl.filter((x) => x !== id), x = excl.filter((x) => x !== id);
		if (incl.includes(id)) x.push(id); else if (!excl.includes(id)) i.push(id);
		// reset: false keeps scroll and focus, so the menu stays open for the next pick
		setParams({ root: i.join(','), not: x.join(',') }, { reset: false });
	}
	// "Needs you" is folded by default; ?needs=1 keeps it open (shareable, survives reload)
	const needsOpen = $derived(page.url.searchParams.get('needs') === '1');
	// escalations list options inline ("... (A) do x; (B) do y. Recommended: A"): one line per option + the recommendation
	const toggleNeeds = () => setParam('needs', needsOpen ? '' : '1', { replace: true, reset: false });

	// drag & drop: drop on a card = place before it, drop on the column = append
	let dragging = $state<number | null>(null);
	let over = $state<string | null>(null);
	async function drop(status: TaskStatus, before: Task | null) {
		const t = dragging === null ? undefined : byId.get(dragging);
		dragging = null; over = null;
		if (!t) return;
		const col = column(status).filter((x) => x.id !== t.id);
		const i = before ? col.findIndex((x) => x.id === before.id) : col.length;
		const prev = col[i - 1]?.position, next = col[i]?.position;
		const position = prev === undefined && next === undefined ? 0 : prev === undefined ? next! - 1 : next === undefined ? prev + 1 : (prev + next) / 2;
		if (t.status === status && t.position === position) return;
		const old = { status: t.status, position: t.position };
		t.status = status; t.position = position; // optimistic
		try {
			await api('/rpc/task_update', { body: { id: t.id, status: status === old.status ? null : status, position } });
		} catch (e) {
			Object.assign(t, old);
			error = (e as Error).message;
		}
		load();
	}

	// new task
	let adding = $state(false);
	let draft = $state({ title: '', assignee: '', parent: '', description: '', check_every: '1d' });
	async function create(e: SubmitEvent) {
		e.preventDefault();
		busy = true;
		try {
			await api('/rpc/task_create', { body: {
				title: draft.title, description: draft.description, assignee: draft.assignee || null,
				parent: Number(draft.parent) || root || null, check_every: draft.check_every || null } });
			draft = { title: '', assignee: '', parent: '', description: '', check_every: '1d' };
			adding = false;
			await load();
		} catch (e) { error = (e as Error).message; }
		finally { busy = false; }
	}

	// reply to a "Needs you" item in place: a note from the human answers the escalation (task_update clears it
	// and tells the PM and the assignee), so the item moves to "Answered recently" on the reload. The form opens
	// from a small "reply" button that shows on hovering the item (always, on touch screens); drafts survive
	// the 15 s refresh and closing the form.
	let replying = $state<number | null>(null);
	let replies = $state<Record<number, string>>({});
	async function reply(t: Task) {
		const note = (replies[t.id] ?? '').trim();
		if (!note) return;
		busy = true;
		try {
			await api('/rpc/task_update', { body: { id: t.id, note } });
			delete replies[t.id];
			replying = null;
			await load();
		} catch (e) { error = (e as Error).message; }
		finally { busy = false; }
	}
	function replyKey(e: KeyboardEvent, t: Task) {
		if (e.key === 'Enter' && (e.ctrlKey || e.metaKey)) { e.preventDefault(); reply(t); }
		else if (e.key === 'Escape') replying = null;
	}
	const focus = (el: HTMLElement) => { el.focus(); };
</script>

<div class="head">
	<h1>Tasks {#if root && byId.get(root)}<span class="muted">› <a href="/tasks/{root}">#{root}/ {byId.get(root)?.title}</a></span>{/if}</h1>
	<!-- project picker: a small menu instead of a native <select>, whose menus ignore option colours
	     on most platforms, so each project's colour square really shows -->
	<div class="proj" onfocusout={(e) => { if (!e.currentTarget.contains(e.relatedTarget as Node)) projOpen = false; }}>
		<button type="button" class="proj-btn" aria-haspopup="listbox" aria-expanded={projOpen}
			onclick={() => (projOpen = !projOpen)} onkeydown={(e) => e.key === 'Escape' && (projOpen = false)}>
			{#if root && byId.get(root)}<span class="sw" style="background: hsl({hue(root)} 65% 50%)"></span>#{root}/ {byId.get(root)?.title}{#if excl.length}, {excl.length} hidden{/if}
			{:else if projLabel}{projLabel}
			{:else}All projects{/if}
			<span class="caret">▾</span>
		</button>
		{#if projOpen}
			<div class="proj-menu panel" role="listbox" tabindex="-1" onkeydown={(e) => e.key === 'Escape' && (projOpen = false)}>
				<button type="button" role="option" aria-selected={!incl.length && !excl.length} class:on={!incl.length && !excl.length}
					onclick={() => { projOpen = false; setParams({ root: '', not: '' }); }}><span class="sw none"></span>All projects</button>
				<div class="hint muted">click: show only · again: hide · again: reset</div>
				{#each roots as r}
					{@const state = incl.includes(r.id) ? 'in' : excl.includes(r.id) ? 'out' : ''}
					<div class="opt">
						<button type="button" role="option" aria-selected={state === 'in'} class:on={state === 'in'} class:off={state === 'out'}
							title={state === 'in' ? 'shown: click to hide it' : state === 'out' ? 'hidden: click to reset' : 'click to show only the picked projects'}
							onclick={() => cycle(r.id)}>
							<span class="mark">{state === 'in' ? '✓' : state === 'out' ? '✕' : ''}</span>
							<span class="sw" style="background: hsl({hue(r.id)} 65% 50%)"></span><span class="name">#{r.id} {r.title}</span>
						</button>
						<button type="button" class="only" title="show only this project"
							onclick={() => { projOpen = false; setParams({ root: String(r.id), not: '' }); }}>only</button>
					</div>
				{/each}
			</div>
		{/if}
	</div>
	<select value={who} onchange={(e) => setParam('who', e.currentTarget.value)}>
		<option value="">Everyone</option>
		{#each agents as a}<option value={a.handle}>{a.handle}</option>{/each}
	</select>
	<button onclick={() => (adding = !adding)}>{adding ? 'Close' : 'New task'}</button>
</div>
{#if error}<p class="error">{error}</p>{/if}

{#if adding}
	<form class="panel new" onsubmit={create}>
		<input bind:value={draft.title} placeholder="Title" required />
		<div class="row">
			<select bind:value={draft.assignee}>
				<option value="">Unassigned</option>
				{#each agents as a}<option value={a.handle}>{a.handle}</option>{/each}
			</select>
			<select bind:value={draft.parent}>
				<option value="">{root ? `Under #${root}` : 'Top level'}</option>
				{#each tasks as t}<option value={t.id}>under {taskRef(t)} {t.title}</option>{/each}
			</select>
			<input bind:value={draft.check_every} title="the PM checks in when there's no activity for this long (30m, 4h, 1d, 1w)" placeholder="check-in every (1d)" />
		</div>
		<textarea bind:value={draft.description} rows="4" placeholder="What done looks like, context, links to threads (#123)…"></textarea>
		<div><button disabled={busy || !draft.title.trim()}>Create</button></div>
	</form>
{/if}

{#if attention.length || answered.length}
	<div class="attn">
		<button class="attn-head" onclick={toggleNeeds} aria-expanded={needsOpen}>
			<span class="caret">{needsOpen ? '▾' : '▸'}</span> <b>Needs you</b> <span class="muted">{attention.length}</span>
			{#if levelCounts[0]}<span class="lv lv1">{levelCounts[0]} urgent</span>{/if}
		</button>
		{#if needsOpen}
			<ol>
				{#each attention as t, i (t.id)}
					{#if levelStart(attention, i)}<li class="lvh lv{lvl(t)}">{HUMAN_LEVEL[lvl(t)]} <span class="muted">{levelCounts[lvl(t) - 1]}</span></li>{/if}
					{#if groupStart(attention, i)}<li class="grp">{GROUP[labelOf(t).group]}</li>{/if}
					<li class="need lvi{lvl(t)}" value={i + 1}><span class="pname" style="--proj: {projColor(t)}">{projName(t)}</span>
						<a href={taskHref(t)}><b>{taskRef(t)}</b> {t.title}</a>
						{#if replying !== t.id}<button class="link reply" class:draft={!!replies[t.id]} onclick={() => (replying = t.id)}
							title="answer with a note: it clears this from Needs you and tells {t.assignee ?? 'the PM'}">↩ {replies[t.id] ? 'draft' : 'reply'}</button>{/if}
						<select class="rate" value={lvl(t)} disabled={busy} title="how urgent this is (re-rate it)" aria-label="urgency of {taskRef(t)}"
							onchange={(e) => rate(t, Number(e.currentTarget.value))}>
							{#each [1, 2, 3] as l (l)}<option value={l}>{HUMAN_LEVEL[l].toLowerCase()}</option>{/each}
						</select>
						<div class="why"><Md text={t.human_reason ?? ''} /></div>
						{#if replying === t.id}
							<form class="replyform" onsubmit={(e) => { e.preventDefault(); reply(t); }}>
								<textarea rows="2" placeholder="your answer, e.g. (a) approved; Ctrl+Enter sends, Esc closes" bind:value={replies[t.id]}
									onkeydown={(e) => replyKey(e, t)} use:focus></textarea>
								<div><button disabled={busy || !(replies[t.id] ?? '').trim()}>Send</button>
									<button type="button" class="link" onclick={() => (replying = null)}>close</button>
									<span class="muted small">answers it: clears it from Needs you, tells {t.assignee ?? 'the PM'}</span></div>
							</form>
						{/if}</li>
				{/each}
			</ol>
		{:else}
			{#each attnByLevel as [l, ps] (l)}
				<div class="ids"><span class="lv lv{l}">{HUMAN_LEVEL[l]}</span>
				{#each ps as [name, ts], g (name)}{g ? ', ' : ''}<span class="pname" style="--proj: {projColor(ts[0])}">{name}</span>
					({#each ts as t, i (t.id)}{i ? ', ' : ''}<a href={taskHref(t)} title={t.title}>{taskRef(t)}</a>{/each}){/each}</div>
			{/each}
		{/if}
		{#if answered.length}
			<div class="answered">
				<button class="attn-head" onclick={() => setParam('answered', answeredOpen ? '' : '1', { replace: true, reset: false })} aria-expanded={answeredOpen}>
					<span class="caret">{answeredOpen ? '▾' : '▸'}</span> <b>Answered recently</b> <span class="muted">{answered.length} · 7 days</span>
				</button>
				{#if answeredOpen}
					<ol>
						{#each answered as e (e.id)}
							{@const t = byId.get(e.task_id)!}
							<li><span class="pname" style="--proj: {projColor(t)}">{projName(t)}</span>
								<a href={taskHref(t)}><b>{taskRef(t)}</b> {t.title}</a>
								<span class="muted small">· {e.outcome} by {e.ended_by} {ago(e.ended_at ?? '')}</span>
								{#if e.answer}<div class="ans"><b>{e.ended_by}:</b> <Body text={e.answer} inline /></div>{/if}
								<details><summary class="muted small">what was asked</summary><div class="why"><Md text={e.reason} /></div></details></li>
						{/each}
					</ol>
				{:else}
					<span class="ids">{#each answered as e, i (e.id)}{i ? ', ' : ''}<a href="/tasks/{e.task_id}" title={e.task_title}>#{e.task_id}</a>{/each}</span>
				{/if}
			</div>
		{/if}
	</div>
{/if}

<div class="board">
	{#each TASK_STATUSES as s}
		<section class="col {s}" class:over={over === s} role="list" aria-label={TASK_LABEL[s]}
			ondragover={(e) => { e.preventDefault(); over = s; }}
			ondragleave={() => (over = over === s ? null : over)}
			ondrop={(e) => { e.preventDefault(); drop(s, null); }}>
			<h2><a href="/tasks/{s}{page.url.search}" title="{TASK_LABEL[s]}, one column per project">{TASK_LABEL[s]}</a> <span class="muted">{column(s).length}</span></h2>
			{#each groupTree(column(s), byId) as { t, depth } (t.id)}
				<a class="card panel" class:sub={depth > 0} href={taskHref(t)} style="--proj: {projColor(t)}; --depth: {depth}" title="project: #{rootOf(t).id} {rootOf(t).title}" draggable="true" class:human={t.needs_human} class:urgent={t.needs_human && lvl(t) === 1} class:dim={dragging === t.id}
					ondragstart={(e) => { dragging = t.id; e.dataTransfer?.setData('text/plain', String(t.id)); }}
					ondragend={() => { dragging = null; over = null; }}
					ondrop={(e) => { e.preventDefault(); e.stopPropagation(); drop(s, t); }}>
					{#if path(t).length && !depth}<div class="path muted">{path(t).map((p) => p.title).join(' › ')}</div>{/if}
					<div class="title"><span class="muted">{taskRef(t)}</span> {t.title}</div>
					{#if t.needs_human}<div class="reason">Needs you{lvl(t) !== 2 ? ` (${HUMAN_LEVEL[lvl(t)].toLowerCase()})` : ''}: {mdTeaser(t.human_reason ?? '')}</div>{/if}
					<div class="meta">
						<span class="chip" class:none={!t.assignee}>{t.assignee ?? 'unassigned'}</span>
						{#if t.subtasks}<span class="muted" title="subtasks done">☑ {t.subtasks_done}/{t.subtasks}</span>{/if}
						{#if t.threads.length}<span class="muted" title="conversations">💬 {t.threads.length}</span>{/if}
						<span class="spacer"></span>
						<span class:late={t.overdue_checkin && s !== 'done'} class="muted" title="last activity">{ago(t.activity_at)}</span>
					</div>
					{#if t.last_note && s !== 'done'}<div class="note muted">{t.last_note}</div>{/if}
				</a>
			{/each}
		</section>
	{/each}
</div>

<style>
	.head { display: flex; gap: 0.6rem; align-items: center; flex-wrap: wrap; margin-bottom: 1rem; }
	.head h1 { margin: 0; flex: 1; min-width: 12rem; }
	.head select { width: auto; max-width: 16rem; }
	.proj { position: relative; }
	.proj-btn { display: flex; align-items: center; gap: 0.4rem; max-width: 18rem; white-space: nowrap; overflow: hidden;
		text-overflow: ellipsis; }
	.caret { margin-left: auto; padding-left: 0.3rem; color: var(--muted); }
	.proj-menu { position: absolute; z-index: 20; top: calc(100% + 4px); left: 0; min-width: 16rem; max-width: min(26rem, 90vw);
		max-height: 60vh; overflow-y: auto; display: grid; padding: 0.3rem; box-shadow: 0 6px 24px rgb(0 0 0 / 0.18); }
	.proj-menu button { display: flex; align-items: center; gap: 0.5rem; text-align: left; background: transparent;
		border: 0; color: var(--ink); padding: 0.35rem 0.5rem; border-radius: 4px; font: inherit; cursor: pointer; }
	.proj-menu button:hover, .proj-menu button.on { background: color-mix(in srgb, var(--line) 45%, transparent); }
	.proj-menu .opt { display: flex; align-items: center; }
	.proj-menu .opt > button:first-child { flex: 1; min-width: 0; }
	.proj-menu .name { overflow: hidden; text-overflow: ellipsis; }
	.proj-menu button.off .name { text-decoration: line-through; color: var(--muted); }
	.proj-menu .mark { flex: none; width: 0.9rem; text-align: center; font-size: 0.8rem; color: var(--accent); }
	.proj-menu button.off .mark { color: #d9480f; }
	.proj-menu .only { flex: none; font-size: 0.75rem; color: var(--muted); padding: 0.2rem 0.4rem; }
	.proj-menu .hint { font-size: 0.72rem; padding: 0.1rem 0.5rem 0.3rem; }
	.sw { flex: none; width: 0.8rem; height: 0.8rem; border-radius: 2px; }
	.sw.none { border: 1px dashed var(--line); }
	.new { display: grid; gap: 0.5rem; padding: 0.8rem; margin-bottom: 1rem; }
	.new .row { display: flex; gap: 0.5rem; flex-wrap: wrap; }
	.new .row > * { flex: 1; min-width: 10rem; }
	.attn { background: color-mix(in srgb, #d9480f 10%, var(--panel)); border-left: 4px solid #d9480f; padding: 0.5rem 0.75rem;
		border-radius: 6px; margin-bottom: 1rem; font-size: 0.9rem; }
	.attn-head { background: none; border: 0; padding: 0; font: inherit; color: inherit; cursor: pointer; }
	.attn .caret { display: inline-block; width: 1em; }
	.attn .ids { margin-left: 0.5rem; }
	.attn ol { margin: 0.5rem 0 0; padding-left: 1.5rem; display: grid; gap: 0.6rem; }
	.attn .pname { display: inline-block; font-size: 0.78rem; font-weight: 600; padding: 0 0.4rem; margin-right: 0.3rem; border-radius: 4px;
		color: var(--proj); background: color-mix(in srgb, var(--proj) 14%, transparent); border: 1px solid color-mix(in srgb, var(--proj) 45%, transparent); }
	.attn .why { margin-top: 0.15rem; }
	/* group headings: Projects / Systems / Operations (doc:systems-and-projects) */
	.attn li.grp { list-style: none; margin: 0.4rem 0 -0.3rem -1.5rem; font-size: 0.75rem; font-weight: 700; letter-spacing: 0.04em;
		text-transform: uppercase; color: var(--muted); }
	.attn li.grp:first-child { margin-top: 0; }
	.attn .grpname { font-size: 0.75rem; font-weight: 700; color: var(--muted); margin-right: 0.2rem; }
	/* urgency levels: urgent red, soon orange, whenever grey */
	.lv { display: inline-block; font-size: 0.72rem; font-weight: 700; padding: 0 0.45rem; border-radius: 999px; margin: 0 0.4rem 0 0.3rem;
		text-transform: uppercase; letter-spacing: 0.03em; }
	.lv1 { background: #c92a2a; color: #fff; }
	.lv2 { background: #d9480f; color: #fff; }
	.lv3 { background: var(--line); color: var(--muted); }
	.attn .ids + .ids { margin-top: 0.25rem; }
	.attn li.lvh { list-style: none; margin: 0.7rem 0 -0.2rem -1.5rem; font-size: 0.85rem; font-weight: 700; background: none;
		color: var(--ink); border-left: 4px solid; padding-left: 0.4rem; text-transform: none; }
	.attn li.lvh:first-child { margin-top: 0; }
	.attn li.lvh.lv1 { border-color: #c92a2a; } .attn li.lvh.lv2 { border-color: #d9480f; } .attn li.lvh.lv3 { border-color: var(--line); }
	.attn li.lvi3 { opacity: 0.85; }
	.attn .rate { margin-left: 0.4rem; font-size: 0.75rem; padding: 0 0.2rem; height: auto; width: auto; }
	.attn .reply { margin-left: 0.4rem; font-size: 0.8rem; opacity: 0; transition: opacity 0.15s; }
	.attn .need:hover .reply, .attn .reply:focus-visible, .attn .reply.draft { opacity: 1; }
	@media (hover: none) { .attn .reply { opacity: 0.8; } }
	.attn .replyform { margin-top: 0.35rem; display: grid; gap: 0.3rem; }
	.attn .replyform textarea { width: 100%; font: inherit; }
	.attn .replyform div { display: flex; gap: 0.6rem; align-items: center; flex-wrap: wrap; }
	.attn .answered { margin-top: 0.4rem; padding-top: 0.4rem; border-top: 1px solid color-mix(in srgb, #d9480f 25%, transparent); }
	.attn .ans { margin-top: 0.15rem; white-space: pre-wrap; }
	.attn details summary { cursor: pointer; }
	.small { font-size: 0.78rem; }
	.board { display: grid; grid-template-columns: repeat(6, minmax(180px, 1fr)); gap: 0.75rem; overflow-x: auto; padding-bottom: 1rem; }
	.col { background: color-mix(in srgb, var(--line) 35%, transparent); border-radius: 8px; padding: 0.5rem; min-height: 8rem;
		display: flex; flex-direction: column; gap: 0.5rem; }
	.col.over { outline: 2px dashed var(--accent); }
	.col h2 { font-size: 0.8rem; text-transform: uppercase; letter-spacing: 0.06em; margin: 0.1rem 0.2rem; }
	.col h2 a { color: inherit; }
	.col.blocked h2 { color: #d9480f; }
	.col.done h2 { color: #2e9d5b; }
	.card { display: grid; gap: 0.3rem; padding: 0.55rem 0.65rem; color: var(--ink); cursor: grab; font-size: 0.88rem;
		border-left: 4px solid var(--proj, var(--line)); background: color-mix(in srgb, var(--proj, transparent) 7%, var(--panel)); }

	.card:hover { text-decoration: none; border-color: var(--accent); }
	.card.human { border-color: #d9480f; box-shadow: 0 0 0 1px #d9480f; }
	.card.human.urgent { border-color: #c92a2a; box-shadow: 0 0 0 2px #c92a2a; }
	.card.dim { opacity: 0.4; }
	/* a subtask under its ancestor in the same column: indented one step per level */
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
