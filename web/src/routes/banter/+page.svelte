<script lang="ts">
	// Banter: daily message volume per agent, as stacked bars. Count or bytes, attributed to the sender or to
	// each recipient. Click a segment (day + agent) or a day's column to list that correspondence below, with
	// its tasks. Or colour it by the tasks the threads are filed under: their top-level task, or their state
	// (now, not when sent). The day's list shows each message's projects, tasks and their state, flags what needs
	// a closer look (a task or thread that needs the human, a blocked task; "Needs attention first" sorts by it),
	// and opens a message inline with its thread's digest as it stood then (api.thread_summary_versions).
	// State lives in the query string (?metric=bytes&by=recipient|task|project|state&range=90&day=...&agent=...&order=attention).
	import { page } from '$app/state';
	import { goto } from '$app/navigation';
	import { api, type ThreadSummary } from '#lib/api.svelte.ts';
	import Body from '#lib/Body.svelte';
	import Summary from '#lib/Summary.svelte';

	type Stat = { id: number; sender: string; thread_id: number; created_at: string; subject: string;
		bytes: number; recipients: string[]; task_ids: number[] };
	type Task = { id: number; path: string; title: string; status: string; needs_human: boolean; kind: string; slug: string | null; project_id: number | null };
	type Thread = { thread_id: number; subject: string; status: string | null; needs_human: boolean; human_reason: string | null;
		summarized_through: number | null; stale: boolean };
	type Version = { thread_id: number; status: 'open' | 'closed'; needs_human: boolean; human_reason: string | null; summary: string;
		summarized_through: number; summarized_at: string; summarized_by: string; source: string };

	let rows = $state<Stat[]>([]);
	let tasks = $state(new Map<number, Task>());
	let error = $state('');
	let loading = $state(true);

	async function load() {
		const all: Stat[] = [];
		for (let last = 0; ; ) { // db-max-rows is 1000: page by id
			const r = await api<Stat[]>(`/message_stats?id=gt.${last}&order=id&limit=1000`);
			all.push(...r.data);
			if (r.data.length < 1000) break;
			last = r.data[r.data.length - 1].id;
		}
		rows = all;
		const t = await api<Task[]>('/tasks?select=id,path,title,status,needs_human,kind,slug,project_id');
		tasks = new Map(t.data.map((x) => [x.id, x]));
	}
	load().catch((e) => (error = e.message)).finally(() => (loading = false));

	const q = $derived(page.url.searchParams);
	const metric = $derived(q.get('metric') === 'bytes' ? 'bytes' : 'count');
	const BYS = ['sender', 'recipient', 'task', 'project', 'state'] as const;
	const by = $derived((BYS as readonly string[]).includes(q.get('by') ?? '') ? (q.get('by') as (typeof BYS)[number]) : 'sender');
	const byTask = $derived(by === 'task' || by === 'project' || by === 'state');
	const range = $derived(['14', '30', '90', 'all'].includes(q.get('range') ?? '') ? q.get('range')! : '30');
	const selDay = $derived(q.get('day') ?? '');
	const selAgent = $derived(q.get('agent') ?? '');
	function setParams(kv: Record<string, string>) {
		const p = new URLSearchParams(page.url.searchParams.toString());
		for (const [k, v] of Object.entries(kv)) v ? p.set(k, v) : p.delete(k);
		goto(`/banter${p.size ? `?${p}` : ''}`, { reset: false, replaceState: true });
	}

	// the keys a message counts for (once each): its sender, each recipient, each distinct top-level task of
	// its thread (root id as a string), or each distinct state of those tasks ('needs you' wins over the
	// status). A thread under no task counts as 'none'.
	const rootOf = (id: number) => { const t = tasks.get(id); return t ? t.path.split('/')[0] : String(id); };
	// the nearest project (doc:systems-and-projects) as its id, or 'ops' for tasks under no project (operations)
	const projOf = (id: number) => { const t = tasks.get(id); return t?.project_id ? String(t.project_id) : 'ops'; };
	const stateOf = (id: number) => { const t = tasks.get(id); return !t ? 'none' : t.needs_human ? 'needs' : t.status; };
	function keysOf(r: Stat, mode: string = by): string[] {
		if (mode === 'sender') return [r.sender];
		if (mode === 'recipient') return r.recipients;
		if (!r.task_ids.length) return ['none'];
		return [...new Set(r.task_ids.map(mode === 'task' ? rootOf : mode === 'project' ? projOf : stateOf))];
	}
	// colors follow the agent (or task), not its rank in the current view: the 8 busiest of all time (agents:
	// sent + received) get the categorical slots in fixed order, everyone else is "other". States have fixed slots.
	const SLOTS = 8;
	const STATES = ['doing', 'blocked', 'done', 'todo', 'cancelled', 'ongoing', 'review', 'needs']; // slot order: doing blue, blocked orange, needs you red ...
	const ranked = $derived.by(() => {
		if (by === 'state') return STATES;
		const n = new Map<string, number>();
		for (const r of rows)
			for (const h of byTask ? keysOf(r, by === 'project' ? 'project' : 'task').filter((k) => k !== 'none') : [r.sender, ...r.recipients]) n.set(h, (n.get(h) ?? 0) + 1);
		return [...n.entries()].sort((a, b) => b[1] - a[1]).map(([h]) => h);
	});
	const named = $derived(ranked.slice(0, SLOTS));
	const keyOf = (h: string) => (h === 'none' || named.includes(h) ? h : 'other');
	const series = $derived([...named, ...(ranked.length > SLOTS ? ['other'] : []), ...(byTask ? ['none'] : [])]);
	const color = (s: string) => (s === 'other' || s === 'none' ? `var(--s-${s})` : `var(--s${named.indexOf(s) + 1})`);
	let hidden = $state(new Set<string>());
	const shownSeries = $derived(series.filter((s) => !hidden.has(s)));
	function toggle(s: string) {
		const h = new Set(hidden);
		h.has(s) ? h.delete(s) : h.add(s);
		hidden = h;
	}

	const dayOf = (ts: string) => ts.slice(0, 10); // created_at is UTC (+00:00)
	const days = $derived.by(() => {
		if (!rows.length) return [] as string[];
		const end = new Date(new Date().toISOString().slice(0, 10) + 'T00:00:00Z');
		const first = new Date(dayOf(rows[0].created_at) + 'T00:00:00Z');
		const start = range === 'all' ? first : new Date(Math.max(+first, +end - (Number(range) - 1) * 864e5));
		const out: string[] = [];
		for (let d = +start; d <= +end; d += 864e5) out.push(new Date(d).toISOString().slice(0, 10));
		return out;
	});
	const inRange = $derived(rows.filter((r) => days.length && dayOf(r.created_at) >= days[0]));
	// the agents a message counts for: its sender, or each of its recipients
	const partiesOf = (r: Stat) => keysOf(r);
	const val = (r: Stat) => (metric === 'bytes' ? r.bytes : 1);

	const agg = $derived.by(() => {
		const m = new Map<string, Map<string, number>>();
		for (const d of days) m.set(d, new Map());
		for (const r of inRange) {
			const dm = m.get(dayOf(r.created_at));
			if (!dm) continue;
			for (const h of partiesOf(r)) { const k = keyOf(h); dm.set(k, (dm.get(k) ?? 0) + val(r)); }
		}
		return m;
	});
	const totals = $derived.by(() => {
		const t = new Map<string, number>();
		for (const dm of agg.values()) for (const [k, v] of dm) t.set(k, (t.get(k) ?? 0) + v);
		return t;
	});
	const dayTotal = (d: string) => shownSeries.reduce((a, s) => a + (agg.get(d)?.get(s) ?? 0), 0);

	const fmtBytes = (b: number) => (b >= 1e6 ? `${(b / 1e6).toFixed(1)} MB` : b >= 1e3 ? `${(b / 1e3).toFixed(b >= 1e4 ? 0 : 1)} KB` : `${b} B`);
	const fmtVal = (v: number) => (metric === 'bytes' ? fmtBytes(v) : String(v));
	const label = (s: string) => {
		if (s === 'other') return by === 'task' ? 'other tasks' : by === 'project' ? 'other projects' : 'other agents';
		if (s === 'none') return 'no task';
		if (by === 'state') return s === 'needs' ? 'needs you' : s;
		if (by === 'project') { if (s === 'ops') return 'operations'; const t = tasks.get(Number(s)); return t ? (t.slug ?? t.title.split(/[:(,]/)[0].slice(0, 28)) : `#${s}`; }
		if (by === 'task') { const t = tasks.get(Number(s)); return t ? `#${s}/ ${t.title.length > 28 ? t.title.slice(0, 27) + '…' : t.title}` : `#${s}/`; }
		return s;
	};

	// ---- geometry
	let W = $state(900);
	const H = 300, ML = 52, MR = 8, MT = 10, MB = 26;
	const max = $derived(Math.max(1, ...days.map(dayTotal)));
	const ticks = $derived.by(() => {
		const raw = max / 4, mag = 10 ** Math.floor(Math.log10(raw));
		const step = [1, 2, 2.5, 5, 10].map((f) => f * mag).find((s) => s >= raw)!;
		const out: number[] = [];
		for (let v = 0; v <= max + step * 0.001; v += step) out.push(v);
		if (out[out.length - 1] < max) out.push(out[out.length - 1] + step);
		return out;
	});
	const top = $derived(ticks[ticks.length - 1] || 1);
	const y = (v: number) => MT + (H - MT - MB) * (1 - v / top);
	const band = $derived((W - ML - MR) / Math.max(1, days.length));
	const barW = $derived(Math.max(2, Math.min(36, band * 0.72)));
	const bx = (i: number) => ML + i * band + (band - barW) / 2;
	const labelEvery = $derived(Math.max(1, Math.ceil(44 / band)));
	type Seg = { s: string; y0: number; y1: number; v: number; top: boolean };
	const stacks = $derived(days.map((d) => {
		let acc = 0;
		const segs: Seg[] = [];
		for (const s of shownSeries) {
			const v = agg.get(d)?.get(s) ?? 0;
			if (!v) continue;
			segs.push({ s, v, y0: y(acc), y1: y(acc + v), top: false });
			acc += v;
		}
		if (segs.length) segs[segs.length - 1].top = true;
		return segs;
	}));
	// a segment: 2px surface gap below it, the top one with 4px rounded corners
	function segPath(x: number, w: number, sg: Seg) {
		const yb = sg.y0 - (sg.y0 - sg.y1 > 3 ? 2 : 0), yt = sg.y1, h = yb - yt;
		if (h <= 0) return '';
		const r = sg.top ? Math.min(4, w / 2, h) : 0;
		return `M${x},${yb}V${yt + r}${r ? `Q${x},${yt} ${x + r},${yt}` : ''}H${x + w - r}${r ? `Q${x + w},${yt} ${x + w},${yt + r}` : ''}V${yb}Z`;
	}

	// ---- hover
	let tip = $state<{ x: number; y: number; d: string; s: string | null } | null>(null);
	let wrap: HTMLDivElement | undefined = $state();
	function hover(e: PointerEvent, d: string, s: string | null) {
		const b = wrap!.getBoundingClientRect();
		tip = { x: e.clientX - b.left, y: e.clientY - b.top, d, s };
	}
	const pick = (d: string, s: string | null) =>
		setParams({ day: selDay === d && selAgent === (s ?? '') ? '' : d, agent: selDay === d && selAgent === (s ?? '') ? '' : (s ?? '') });

	// ---- the selected day's correspondence
	const detail = $derived.by(() => {
		if (!selDay) return [] as Stat[];
		return rows.filter((r) => dayOf(r.created_at) === selDay
			&& (!selAgent || partiesOf(r).some((h) => keyOf(h) === selAgent || h === selAgent)));
	});
	$effect(() => {
		const need = [...new Set(detail.flatMap((r) => r.task_ids))].filter((id) => !tasks.has(id));
		if (!need.length) return;
		api<Task[]>(`/tasks?select=id,path,title,status,needs_human,kind,slug,project_id&id=in.(${need.join(',')})`).then((r) => {
			const m = new Map(tasks);
			for (const t of r.data) m.set(t.id, t);
			tasks = m;
		}).catch(() => {});
	});
	const hhmm = (ts: string) => ts.slice(11, 16) + 'Z';
	let showTable = $state(false);

	// ---- what needs a closer look: the threads' summaries and the tasks' state, per message
	let threads = $state(new Map<number, Thread>());
	$effect(() => {
		const need = [...new Set(detail.map((r) => r.thread_id))].filter((id) => !threads.has(id));
		if (!need.length) return;
		api<Thread[]>(`/threads?select=thread_id,subject,status,needs_human,human_reason,summarized_through,stale&thread_id=in.(${need.join(',')})`).then((r) => {
			const m = new Map(threads);
			for (const t of r.data) m.set(t.thread_id, t);
			threads = m;
		}).catch(() => {});
	});
	const byPath = $derived(new Map([...tasks.values()].map((t) => [t.path, t])));
	// the top-level tasks ("projects") of a message's tasks, except those it is filed under directly (shown as chips)
	// the day list groups by top-level task, or by project in the "By project" view ('ops' = under no project)
	const grpOf = (id: number) => (by === 'project' ? projOf(id) : rootOf(id));
	const grpTask = (k: string) => (by === 'project' ? tasks.get(Number(k)) : byPath.get(k));
	const projectsOf = (r: Stat) => [...new Set(r.task_ids.map(grpOf))].map(grpTask)
		.filter((t): t is Task => !!t && !r.task_ids.includes(t.id));
	// flags, most urgent first; weight orders the list in "attention first"
	function flagsOf(r: Stat): { k: string; text: string; tip: string }[] {
		const out: { k: string; text: string; tip: string }[] = [];
		const th = threads.get(r.thread_id);
		const tk = r.task_ids.map((id) => tasks.get(id)).filter((t): t is Task => !!t);
		if (th?.needs_human) out.push({ k: 'needs', text: 'thread needs you', tip: th.human_reason ?? '' });
		const tn = tk.filter((t) => t.needs_human);
		if (tn.length) out.push({ k: 'needs', text: `task needs you`, tip: tn.map((t) => `#${t.path} ${t.title}`).join('\n') });
		const tb = tk.filter((t) => t.status === 'blocked');
		if (tb.length) out.push({ k: 'blocked', text: 'task blocked', tip: tb.map((t) => `#${t.path} ${t.title}`).join('\n') });
		if (th && th.status === 'open' && !th.needs_human) out.push({ k: 'open', text: 'thread open', tip: 'someone still owes something' });
		if (th && !th.status) out.push({ k: 'new', text: 'not summarized', tip: '' });
		return out;
	}
	const weight = (r: Stat) => flagsOf(r).reduce((a, f) => a + ({ needs: 100, blocked: 10, open: 1, new: 1 }[f.k] ?? 0), 0);
	const order = $derived(q.get('order') === 'attention' ? 'attention' : 'time');
	const shown = $derived(order === 'attention' ? [...detail].sort((a, b) => weight(b) - weight(a) || a.id - b.id) : detail);
	const attnCount = $derived(detail.filter((r) => weight(r) >= 10).length);
	// the day's projects (top-level tasks), with how many of their messages need a closer look
	const dayProjects = $derived.by(() => {
		const m = new Map<string, { t: Task | undefined; n: number; attn: number }>();
		for (const r of detail) {
			const roots = r.task_ids.length ? [...new Set(r.task_ids.map(grpOf))] : ['none'];
			for (const p of roots) {
				const e = m.get(p) ?? { t: grpTask(p), n: 0, attn: 0 };
				e.n++; if (weight(r) >= 10) e.attn++;
				m.set(p, e);
			}
		}
		return [...m.entries()].sort((a, b) => b[1].attn - a[1].attn || b[1].n - a[1].n);
	});
	let proj = $state('');
	$effect(() => { void selDay; proj = ''; });
	const listed = $derived(proj ? shown.filter((r) => (r.task_ids.length ? r.task_ids.map(grpOf) : ['none']).includes(proj)) : shown);
	const stateColor = (t: Task) => `var(--s${STATES.indexOf(t.needs_human ? 'needs' : t.status) + 1})`;

	// ---- one message opened inline: its body, and the thread's digest as it stood at that message
	let open = $state(new Set<number>());
	let bodies = $state(new Map<number, string>());
	let versions = $state(new Map<number, Version[]>());
	async function toggleOpen(r: Stat) {
		const o = new Set(open);
		if (o.has(r.id)) { o.delete(r.id); open = o; return; }
		o.add(r.id); open = o;
		if (!bodies.has(r.id))
			api<{ body: string }[]>(`/messages?select=body&id=eq.${r.id}`).then((x) => { bodies = new Map(bodies).set(r.id, x.data[0]?.body ?? ''); }).catch(() => {});
		if (!versions.has(r.thread_id))
			api<Version[]>(`/thread_summary_versions?thread_id=eq.${r.thread_id}&order=summarized_through,summarized_at`)
				.then((x) => { versions = new Map(versions).set(r.thread_id, x.data); }).catch(() => {});
	}
	// the first summary that covers this message (written right after it); else the newest before it
	function digestAt(r: Stat): { s: ThreadSummary; when: 'after' | 'before' } | null {
		const vs = versions.get(r.thread_id);
		if (!vs?.length) return null;
		const after = vs.find((v) => v.summarized_through >= r.id);
		const v = after ?? vs[vs.length - 1];
		return { when: after ? 'after' : 'before',
			s: { ...v, stale: false, read_only_reason: null } as unknown as ThreadSummary };
	}
</script>


<h1>Banter</h1>
<div class="controls">
	<div class="seg" role="group" aria-label="Measure">
		<button class:on={metric === 'count'} onclick={() => setParams({ metric: '' })}>Messages</button>
		<button class:on={metric === 'bytes'} onclick={() => setParams({ metric: 'bytes' })}>Bytes</button>
	</div>
	<div class="seg" role="group" aria-label="Count each message for">
		<button class:on={by === 'sender'} onclick={() => setParams({ by: '', agent: '' })}>By sender</button>
		<button class:on={by === 'recipient'} onclick={() => setParams({ by: 'recipient', agent: '' })}>By recipient</button>
		<button class:on={by === 'task'} onclick={() => setParams({ by: 'task', agent: '' })}>By task</button>
		<button class:on={by === 'project'} onclick={() => setParams({ by: 'project', agent: '' })}>By project</button>
		<button class:on={by === 'state'} onclick={() => setParams({ by: 'state', agent: '' })}>By task state</button>
	</div>
	<div class="seg" role="group" aria-label="Range">
		{#each ['14', '30', '90', 'all'] as r}
			<button class:on={range === r} onclick={() => setParams({ range: r === '30' ? '' : r })}>{r === 'all' ? 'All' : `${r} days`}</button>
		{/each}
	</div>
	<span class="muted hint">UTC days. {by === 'recipient' ? 'A message to 3 agents counts once for each.' : by === 'task' ? 'A message counts once for each top-level task its thread is filed under.' : by === 'project' ? 'A message counts once for each project (the nearest one) its thread’s tasks belong to; tasks under no project are operations.' : by === 'state' ? 'The tasks’ state now, not when sent; a message counts once per distinct state.' : 'Each message counts once, for its sender.'}</span>
</div>

{#if error}<p class="error">{error}</p>{:else if loading}<p class="muted">loading…</p>{:else}
	<div class="legend">
		{#each series as s}
			<button class="item" class:off={hidden.has(s)} onclick={() => toggle(s)} title="show/hide {label(s)}">
				<span class="sw" style:background={color(s)}></span>{label(s)}
				<span class="muted">{fmtVal(totals.get(s) ?? 0)}</span>
			</button>
		{/each}
		<span class="muted total">total {fmtVal([...totals.entries()].filter(([k]) => !hidden.has(k)).reduce((a, [, v]) => a + v, 0))}</span>
	</div>

	<div class="chart panel" bind:this={wrap} bind:clientWidth={W} onpointerleave={() => (tip = null)} role="img"
		aria-label="Stacked bars: {metric === 'bytes' ? 'bytes' : 'messages'} per day per agent">
		<svg width={W} height={H}>
			{#each ticks as t}
				<line class="grid" x1={ML} x2={W - MR} y1={y(t)} y2={y(t)} />
				<text class="axis" x={ML - 6} y={y(t)} dy="0.32em" text-anchor="end">{fmtVal(t)}</text>
			{/each}
			{#each days as d, i}
				<!-- the whole column is the hit target for "this day" -->
				<rect class="col" class:sel={selDay === d} x={ML + i * band} y={MT} width={band} height={H - MT - MB}
					onpointermove={(e) => hover(e, d, null)} onclick={() => pick(d, null)} role="presentation" />
				{#each stacks[i] as sg}
					<path d={segPath(bx(i), barW, sg)} fill={color(sg.s)}
						class:dim={!!selDay && (selDay !== d || (!!selAgent && selAgent !== sg.s))}
						onpointermove={(e) => { e.stopPropagation(); hover(e, d, sg.s); }}
						onclick={(e) => { e.stopPropagation(); pick(d, sg.s); }} role="presentation" />
				{/each}
				{#if i % labelEvery === 0}
					<text class="axis" x={ML + i * band + band / 2} y={H - MB + 16} text-anchor="middle">{d.slice(5)}</text>
				{/if}
			{/each}
			<line class="base" x1={ML} x2={W - MR} y1={y(0)} y2={y(0)} />
		</svg>
		{#if tip}
			<div class="tip" style:left="{Math.min(tip.x + 14, W - 230)}px" style:top="{Math.max(0, tip.y - 20)}px">
				<div class="tday">{tip.d} · {fmtVal(dayTotal(tip.d))}</div>
				{#each [...shownSeries].reverse() as s}
					{@const v = agg.get(tip.d)?.get(s) ?? 0}
					{#if v}
						<div class="trow" class:hi={tip.s === s}><span class="sw" style:background={color(s)}></span>{label(s)}<b>{fmtVal(v)}</b></div>
					{/if}
				{/each}
				<div class="muted small">click to list {tip.s ? `${label(tip.s)}'s` : 'the day’s'} messages</div>
			</div>
		{/if}
	</div>

	<p><button class="link" onclick={() => (showTable = !showTable)}>{showTable ? 'hide' : 'show'} table</button></p>
	{#if showTable}
		<div class="tablewrap panel">
			<table>
				<thead><tr><th>day</th>{#each shownSeries as s}<th>{label(s)}</th>{/each}<th>total</th></tr></thead>
				<tbody>
					{#each [...days].reverse() as d}
						<tr><td class="mono"><button class="link" onclick={() => pick(d, null)}>{d}</button></td>
							{#each shownSeries as s}<td>{agg.get(d)?.get(s) ? fmtVal(agg.get(d)!.get(s)!) : ''}</td>{/each}
							<td><b>{fmtVal(dayTotal(d))}</b></td></tr>
					{/each}
				</tbody>
			</table>
		</div>
	{/if}

	{#if selDay}
		<section class="detail">
			<h2>
				{selDay}{#if selAgent}{' · '}{by === 'sender' ? 'sent by' : by === 'recipient' ? 'received by' : by === 'task' || by === 'project' ? 'under' : 'tasks'} {label(selAgent)}{/if}
				<span class="muted">· {detail.length} message{detail.length === 1 ? '' : 's'}, {fmtBytes(detail.reduce((a, r) => a + r.bytes, 0))}</span>
				<button class="link" onclick={() => setParams({ day: '', agent: '' })}>clear</button>
			</h2>
			<div class="projects">
				<span class="muted small">projects:</span>
				<button class="pj" class:on={!proj} onclick={() => (proj = '')}>all <span class="muted">{detail.length}</span></button>
				{#each dayProjects as [p, e] (p)}
					<button class="pj" class:on={proj === p} onclick={() => (proj = proj === p ? '' : p)} title={e.t ? `#${e.t.path}${e.t.path.includes('/') ? '' : '/'} ${e.t.title}` : p === 'ops' ? 'tasks under no project' : 'messages in threads not filed under a task'}>
						{p === 'none' ? 'no task' : p === 'ops' ? 'operations' : by === 'project' && e.t ? (e.t.slug ?? e.t.title.split(/[:(,]/)[0].slice(0, 32)) : `#${p}/ ${e.t ? e.t.title.split(/[:(,]/)[0].slice(0, 32) : ''}`}
						<span class="muted">{e.n}</span>{#if e.attn}<span class="attn-n" title="messages that need a closer look">{e.attn}</span>{/if}
					</button>
				{/each}
			</div>
			<div class="orderbar">
				<div class="seg" role="group" aria-label="Order">
					<button class:on={order === 'time'} onclick={() => setParams({ order: '' })}>By time</button>
					<button class:on={order === 'attention'} onclick={() => setParams({ order: 'attention' })}>Needs attention first</button>
				</div>
				<span class="muted small">{attnCount} of {detail.length} touch a task or thread that needs you or is blocked. Click a row's ▸ to read it here, with the thread's digest at that point.</span>
			</div>
			<ul>
				{#each listed as r (r.id)}
					{@const fl = flagsOf(r)}
					{@const isOpen = open.has(r.id)}
					<li class:attn={fl.some((f) => f.k === 'needs')} class:warn={!fl.some((f) => f.k === 'needs') && fl.some((f) => f.k === 'blocked')}>
						<div class="row">
							<button class="exp" onclick={() => toggleOpen(r)} aria-expanded={isOpen} title={isOpen ? 'hide' : 'read it here'}>{isOpen ? '▾' : '▸'}</button>
							<span class="mono muted">{hhmm(r.created_at)}</span>
							<span class="who"><a href="/?involving={r.sender}">{r.sender}</a> → {#each r.recipients as h, j}{j ? ', ' : ''}<a href="/?involving={h}">{h}</a>{/each}</span>
							<a href="/m/{r.id}">{r.subject}</a>
							<a class="muted small" href="/m/{r.thread_id}" title="the full correspondence">{r.thread_id !== r.id ? `thread #${r.thread_id}` : 'thread'} →</a>
							<span class="muted small">{fmtBytes(r.bytes)}</span>
							{#each fl as f}<span class="flag {f.k}" title={f.tip}>{f.text}</span>{/each}
						</div>
						{#if r.task_ids.length}
							<div class="row tasksrow">
								{#each projectsOf(r) as pt}
									<a class="proj" href="/tasks/{pt.path}" title={pt.title}>#{pt.path}{pt.path.includes('/') ? '' : '/'} {pt.title.split(/[:(,]/)[0].slice(0, 40)}</a>
								{/each}
								{#each r.task_ids as t}
									{@const tk = tasks.get(t)}
									<a class="chip" href="/tasks/{tk?.path ?? t}" title={tk ? `${tk.title} (${tk.needs_human ? 'needs you' : tk.status})` : ''}>
										{#if tk}<span class="st" style:background={stateColor(tk)}>{tk.needs_human ? 'needs you' : tk.status}</span>{/if}
										#{tk ? (tk.path.includes('/') ? tk.path : `${tk.path}/`) : t}{tk ? ` ${tk.title.slice(0, 48)}${tk.title.length > 48 ? '…' : ''}` : ''}</a>
								{/each}
							</div>
						{/if}
						{#if isOpen}
							{@const dg = digestAt(r)}
							<div class="inline">
								{#if bodies.has(r.id)}<div class="body"><Body text={bodies.get(r.id)!} /></div>{:else}<p class="muted small">loading…</p>{/if}
								{#if dg}
									<p class="muted small dgh">{dg.when === 'after'
										? `Thread digest as of #${dg.s.summarized_through}, the first one written after this message:`
										: `Thread digest through #${dg.s.summarized_through}, the newest so far; it was written before this message:`}</p>
									<Summary s={dg.s} />
								{:else if versions.has(r.thread_id)}
									<p class="muted small">This thread has no digest yet.</p>
								{/if}
								<p class="small"><a href="/m/{r.thread_id}">open the full correspondence →</a></p>
							</div>
						{/if}
					</li>
				{:else}
					<li class="muted">no messages</li>
				{/each}
			</ul>
		</section>
	{/if}
{/if}

<style>
	/* categorical slots (validated set, fixed order), stepped separately for the dark surface */
	:global(:root) {
		--s1: #2a78d6; --s2: #eb6834; --s3: #1baf7a; --s4: #eda100; --s5: #e87ba4; --s6: #008300; --s7: #6250d6; --s8: #e34948;
		--s-other: #a3a29c; --s-none: #d6d5cf;
	}
	@media (prefers-color-scheme: dark) {
		:global(:root) {
			--s1: #3987e5; --s2: #d95926; --s3: #199e70; --s4: #c98500; --s5: #d55181; --s6: #008300; --s7: #9085e9; --s8: #e66767;
			--s-other: #6b6b66; --s-none: #4a4a46;
		}
	}
	.controls { display: flex; flex-wrap: wrap; gap: 0.6rem 1rem; align-items: center; margin-bottom: 0.8rem; }
	.seg { display: inline-flex; border: 1px solid var(--line); border-radius: 6px; overflow: hidden; }
	.seg button { background: var(--panel); color: var(--muted); border: 0; border-radius: 0; padding: 0.3rem 0.7rem; font-weight: 500; font-size: 0.88rem; }
	.seg button + button { border-left: 1px solid var(--line); }
	.seg button.on { background: var(--accent-soft); color: var(--ink); }
	.hint { font-size: 0.8rem; }
	.legend { display: flex; flex-wrap: wrap; gap: 0.3rem 0.9rem; align-items: center; margin-bottom: 0.5rem; }
	.legend .item { background: none; border: 0; padding: 0.1rem 0; color: var(--ink); font-weight: 500; font-size: 0.88rem; display: inline-flex; gap: 0.35rem; align-items: center; }
	.legend .item.off { opacity: 0.4; text-decoration: line-through; }
	.legend .total { font-size: 0.85rem; margin-left: auto; }
	.sw { width: 10px; height: 10px; border-radius: 3px; display: inline-block; flex: none; }
	.chart { position: relative; padding: 0.5rem 0; }
	.panel { background: var(--panel); border: 1px solid var(--line); border-radius: 8px; }
	svg { display: block; }
	.grid { stroke: var(--line); stroke-width: 1; }
	.base { stroke: var(--muted); stroke-width: 1; }
	.axis { fill: var(--muted); font-size: 11px; font-family: var(--mono); }
	.col { fill: transparent; cursor: pointer; }
	.col:hover { fill: color-mix(in srgb, var(--line) 45%, transparent); }
	.col.sel { fill: color-mix(in srgb, var(--accent-soft) 80%, transparent); }
	path { cursor: pointer; }
	path.dim { opacity: 0.35; }
	.tip { position: absolute; pointer-events: none; background: var(--panel); border: 1px solid var(--line); border-radius: 6px;
		padding: 0.4rem 0.55rem; font-size: 0.8rem; box-shadow: 0 4px 14px rgb(0 0 0 / 0.15); min-width: 180px; z-index: 2; }
	.tday { font-weight: 600; margin-bottom: 0.2rem; font-family: var(--mono); }
	.trow { display: flex; gap: 0.4rem; align-items: center; }
	.trow b { margin-left: auto; font-weight: 500; font-family: var(--mono); }
	.trow.hi { font-weight: 700; }
	.small { font-size: 0.75rem; }
	button.link { background: none; border: 0; padding: 0; color: var(--accent); font-weight: 500; cursor: pointer; }
	.tablewrap { overflow-x: auto; max-height: 420px; }
	table { border-collapse: collapse; font-size: 0.82rem; width: 100%; }
	th, td { padding: 0.2rem 0.5rem; border-bottom: 1px solid var(--line); text-align: right; white-space: nowrap; }
	th:first-child, td:first-child { text-align: left; }
	th { position: sticky; top: 0; background: var(--panel); }
	.detail h2 { font-size: 1.05rem; margin: 1.2rem 0 0.5rem; }
	.detail ul { list-style: none; padding: 0; margin: 0; }
	.detail li { padding: 0.35rem 0; border-bottom: 1px solid var(--line); display: flex; flex-wrap: wrap; gap: 0.25rem 0.6rem; align-items: baseline; }
	.detail .who { font-size: 0.85rem; }
	.detail li { display: block; border-left: 3px solid transparent; padding-left: 0.4rem; }
	.detail li.attn { border-left-color: var(--s8); }
	.detail li.warn { border-left-color: var(--s2); }
	.detail .row { display: flex; flex-wrap: wrap; gap: 0.25rem 0.6rem; align-items: baseline; }
	.detail .tasksrow { margin: 0.15rem 0 0 1.6rem; }
	.exp { background: none; border: 0; padding: 0 0.2rem; color: var(--muted); cursor: pointer; font-size: 0.85rem; width: 1.2rem; }
	.flag { font-size: 0.72rem; padding: 0 0.4rem; border-radius: 999px; border: 1px solid var(--line); color: var(--muted); }
	.flag.needs { background: var(--s8); color: #fff; border-color: transparent; }
	.flag.blocked { background: var(--s2); color: #fff; border-color: transparent; }
	.proj { font-size: 0.78rem; font-weight: 600; color: var(--ink); }
	.st { font-size: 0.68rem; color: #fff; padding: 0 0.3rem; border-radius: 3px; margin-right: 0.25rem; }
	.inline { margin: 0.4rem 0 0.3rem 1.6rem; display: grid; gap: 0.4rem; }
	.inline .body { max-height: 420px; overflow: auto; border: 1px solid var(--line); border-radius: 6px; padding: 0.4rem 0.6rem; background: var(--panel); }
	.inline p { margin: 0; }
	.projects { display: flex; flex-wrap: wrap; gap: 0.3rem; align-items: center; margin-bottom: 0.5rem; }
	.pj { background: var(--panel); border: 1px solid var(--line); border-radius: 999px; padding: 0.1rem 0.6rem; font-size: 0.8rem; color: var(--ink); cursor: pointer; display: inline-flex; gap: 0.3rem; align-items: center; }
	.pj.on { background: var(--accent-soft); }
	.attn-n { background: var(--s8); color: #fff; border-radius: 999px; padding: 0 0.35rem; font-size: 0.7rem; }
	.orderbar { display: flex; flex-wrap: wrap; gap: 0.4rem 0.8rem; align-items: center; margin-bottom: 0.4rem; }
</style>
