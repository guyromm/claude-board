<script lang="ts">
	// Load: how much each agent's Claude session worked, and on what. The watchers (v16+) push the session's active
	// minutes hourly, with the tasks and threads it mentioned (api.activity_push); the board cuts them into periods
	// (runs of active minutes) and paints each minute with the board objects mentioned last in its stretch of the
	// period (api.activity_load / api.activity_periods, sql/bootstrap.sql "Claude activity").
	// One bar per agent, split by task (top-level task, or the exact task); click an agent for its days and periods.
	// State lives in the query string (?range=7|30|90|all|today|yesterday|custom&from=&to=&by=root|task&agent=).
	import { page } from '$app/state';
	import { goto } from '$app/navigation';
	import { api } from '#lib/api.svelte.ts';

	type Row = { handle: string; day: string | null; target: string; minutes: number; periods: number };
	type Period = { handle: string; started: string; ended: string; minutes: number; lines: number;
		targets: { target: string; minutes: number }[]; drivers: string[] };
	type Task = { id: number; path: string; title: string; status: string; parent_id: number | null };

	const q = $derived(page.url.searchParams);
	const RANGES = ['today', 'yesterday', '7', '30', '90', 'all', 'custom'] as const;
	const range = $derived((RANGES as readonly string[]).includes(q.get('range') ?? '') ? q.get('range')! : '7');
	const by = $derived(q.get('by') === 'task' ? 'task' : 'root');
	const selAgent = $derived(q.get('agent') ?? '');
	const today = new Date().toISOString().slice(0, 10);
	const addDays = (d: string, n: number) => new Date(+new Date(d + 'T00:00:00Z') + n * 864e5).toISOString().slice(0, 10);
	// [from, to) as UTC days; 'to' is exclusive
	const span = $derived.by(() => {
		if (range === 'today') return { from: today, to: addDays(today, 1) };
		if (range === 'yesterday') return { from: addDays(today, -1), to: today };
		if (range === 'all') return { from: '2026-01-01', to: addDays(today, 1) };
		if (range === 'custom') {
			const f = q.get('from') || addDays(today, -6), t = q.get('to') || today;
			return { from: f, to: addDays(t < f ? f : t, 1) };
		}
		return { from: addDays(today, 1 - Number(range)), to: addDays(today, 1) };
	});
	function setParams(kv: Record<string, string>) {
		const p = new URLSearchParams(page.url.searchParams.toString());
		for (const [k, v] of Object.entries(kv)) v ? p.set(k, v) : p.delete(k);
		goto(`/load${p.size ? `?${p}` : ''}`, { replaceState: true });
	}

	let rows = $state<Row[]>([]);
	let allTime = $state<Row[]>([]);
	let tasks = $state(new Map<number, Task>());
	let threads = $state(new Map<number, string>());
	let periods = $state<Period[]>([]);
	let error = $state('');
	let loading = $state(true);

	const iso = (d: string) => `${d}T00:00:00Z`;
	// db-max-rows is 1000: page through an rpc result (ordered, so the pages don't overlap)
	async function all<T>(path: string, order: string): Promise<T[]> {
		const out: T[] = [];
		for (let off = 0; ; off += 1000) {
			const r = await api<T[]>(`${path}&order=${order}&limit=1000&offset=${off}`);
			out.push(...r.data);
			if (r.data.length < 1000) return out;
		}
	}
	$effect(() => {
		const { from, to } = span;
		loading = true;
		all<Row>(`/rpc/activity_load?since=${iso(from)}&until=${iso(to)}&bucket=day`, 'handle,day,target')
			.then((r) => { rows = r.map((x) => ({ ...x, minutes: Number(x.minutes) })); error = ''; })
			.catch((e) => (error = e.message)).finally(() => (loading = false));
	});
	// colours follow the task (or agent), ranked by all-time load, not by the current view
	all<Row>(`/rpc/activity_load?since=2026-01-01T00:00:00Z&bucket=total`, 'handle,target').then((r) => (allTime = r.map((x) => ({ ...x, minutes: Number(x.minutes) })))).catch(() => {});
	api<Task[]>('/tasks?select=id,path,title,status,parent_id').then((r) => (tasks = new Map(r.data.map((t) => [t.id, t])))).catch(() => {});
	$effect(() => {
		const need = [...new Set([...rows, ...periods.flatMap((p) => p.targets.map((t) => ({ target: t.target })))]
			.map((r) => r.target).filter((t) => t.startsWith('h')).map((t) => Number(t.slice(1))))].filter((id) => !threads.has(id));
		if (!need.length) return;
		api<{ thread_id: number; subject: string }[]>(`/threads?select=thread_id,subject&thread_id=in.(${need.join(',')})`).then((r) => {
			const m = new Map(threads);
			for (const t of r.data) m.set(t.thread_id, t.subject);
			for (const id of need) if (!m.has(id)) m.set(id, '');
			threads = m;
		}).catch(() => {});
	});
	$effect(() => {
		const { from, to } = span;
		if (!selAgent) { periods = []; return; }
		all<Period>(`/rpc/activity_periods?since=${iso(from)}&until=${iso(to)}&who=${encodeURIComponent(selAgent)}`, 'started.desc')
			.then((r) => (periods = r)).catch((e) => (error = e.message));
	});

	// ---- series: a target -> its key (top-level task "r<path>", exact task "t<id>", a thread under no task, untagged)
	const rootPath = (id: number) => tasks.get(id)?.path.split('/')[0];
	function keyOf(target: string, mode = by): string {
		if (!target) return 'none';
		if (target.startsWith('h')) return 'thread';
		const id = Number(target.slice(1));
		if (mode === 'task') return target;
		const r = rootPath(id);
		return r ? `r${r}` : target;
	}
	const SLOTS = 8;
	const ranked = $derived.by(() => {
		const n = new Map<string, number>();
		for (const r of allTime.length ? allTime : rows) { const k = keyOf(r.target); if (k !== 'none' && k !== 'thread') n.set(k, (n.get(k) ?? 0) + r.minutes); }
		return [...n.entries()].sort((a, b) => b[1] - a[1]).map(([k]) => k);
	});
	const named = $derived(ranked.slice(0, SLOTS));
	const seriesOf = (k: string) => (k === 'none' || k === 'thread' || named.includes(k) ? k : 'other');
	const color = (s: string) => (s === 'other' ? 'var(--s-other)' : s === 'none' ? 'var(--s-none)' : s === 'thread' ? 'var(--s-thread)' : `var(--s${named.indexOf(s) + 1})`);
	const short = (t: string, n = 30) => (t.length > n ? t.slice(0, n - 1) + '…' : t);
	function label(k: string): string {
		if (k === 'none') return 'no task mentioned';
		if (k === 'thread') return 'threads under no task';
		if (k === 'other') return by === 'root' ? 'other projects/tasks' : 'other tasks';
		if (k.startsWith('r')) { const p = k.slice(1); const t = [...tasks.values()].find((x) => x.path === p); return `#${p}/ ${t ? short(t.title.split(/[:(]/)[0].trim(), 26) : ''}`; }
		if (k.startsWith('t')) { const t = tasks.get(Number(k.slice(1))); return t ? `#${t.path}${t.parent_id ? '' : '/'} ${short(t.title, 26)}` : `task id ${k.slice(1)}`; }
		return k;
	}
	function targetLabel(target: string): { text: string; href: string } {
		if (!target) return { text: 'no task mentioned', href: '' };
		if (target.startsWith('h')) { const id = Number(target.slice(1)); const s = threads.get(id); return { text: `#${id} ${s ? short(s, 40) : ''}`, href: `/m/${id}` }; }
		const t = tasks.get(Number(target.slice(1)));
		return t ? { text: `#${t.path}${t.parent_id ? '' : '/'} ${short(t.title, 40)}`, href: `/tasks/${t.path}` } : { text: `task id ${target.slice(1)}`, href: '' };
	}

	// ---- per agent: total minutes, per series, periods
	const agents = $derived.by(() => {
		const m = new Map<string, { handle: string; total: number; by: Map<string, number>; periods: number; days: Set<string> }>();
		for (const r of rows) {
			const a = m.get(r.handle) ?? { handle: r.handle, total: 0, by: new Map(), periods: 0, days: new Set() };
			const s = seriesOf(keyOf(r.target));
			a.total += r.minutes; a.by.set(s, (a.by.get(s) ?? 0) + r.minutes);
			if (r.day) a.days.add(r.day);
			m.set(r.handle, a);
		}
		// periods per agent: the max per day over targets, summed over days (a period touching two days counts in both)
		const pd = new Map<string, number>();
		for (const r of rows) { const k = `${r.handle}\t${r.day}`; pd.set(k, Math.max(pd.get(k) ?? 0, r.periods)); }
		for (const [k, v] of pd) { const a = m.get(k.split('\t')[0]); if (a) a.periods += v; }
		return [...m.values()].sort((a, b) => b.total - a.total);
	});
	const maxTotal = $derived(Math.max(1, ...agents.map((a) => a.total)));
	const series = $derived([...named, 'other', 'thread', 'none'].filter((s) => agents.some((a) => a.by.has(s))));
	const fmt = (min: number) => (min >= 60 ? `${Math.floor(min / 60)}h${String(Math.round(min % 60)).padStart(2, '0')}` : `${Math.round(min)}m`);
	const grand = $derived(agents.reduce((s, a) => s + a.total, 0));

	// ---- hover tip over a bar segment
	let tip = $state<{ x: number; y: number; html: { k: string; v: number }[]; who: string } | null>(null);
	let wrap: HTMLDivElement | undefined = $state();
	function hover(e: PointerEvent, who: string, list: { k: string; v: number }[]) {
		const b = wrap!.getBoundingClientRect();
		tip = { x: e.clientX - b.left, y: e.clientY - b.top, html: list, who };
	}

	// ---- the selected agent: per day, stacked by series, and its periods
	const days = $derived.by(() => {
		const out: string[] = [];
		for (let d = span.from; d < span.to && out.length < 400; d = addDays(d, 1)) out.push(d);
		return range === 'all' ? out.filter((d) => d >= (rows.map((r) => r.day!).sort()[0] ?? today)) : out;
	});
	const daily = $derived.by(() => {
		const m = new Map<string, Map<string, number>>();
		for (const r of rows) {
			if (r.handle !== selAgent || !r.day) continue;
			const dm = m.get(r.day) ?? new Map();
			const s = seriesOf(keyOf(r.target));
			dm.set(s, (dm.get(s) ?? 0) + r.minutes);
			m.set(r.day, dm);
		}
		return m;
	});
	const dayMax = $derived(Math.max(1, ...days.map((d) => [...(daily.get(d)?.values() ?? [])].reduce((a, b) => a + b, 0))));
	// the agent's load per exact target over the range (a table, also the accessible view of the bars)
	const agentTargets = $derived.by(() => {
		const m = new Map<string, number>();
		for (const r of rows) if (r.handle === selAgent) m.set(r.target, (m.get(r.target) ?? 0) + r.minutes);
		return [...m.entries()].sort((a, b) => b[1] - a[1]);
	});
	const hhmm = (ts: string) => ts.slice(11, 16);
	const pDay = (ts: string) => ts.slice(0, 10);
	let showAll = $state(false);
	const shownPeriods = $derived(showAll ? periods : periods.slice(0, 60));
	const H = 160;
</script>

<div class="head">
	<h1>Load</h1>
	<span class="muted small">Claude activity per agent, from the transcripts (pushed hourly by watcher v16+), split by the tasks and threads the agent mentioned. UTC days.</span>
</div>

<div class="controls">
	<div class="seg" role="group" aria-label="Period">
		{#each RANGES as r (r)}
			<button class:on={range === r} onclick={() => setParams({ range: r === '7' ? '' : r })}>{r === 'today' ? 'Today' : r === 'yesterday' ? 'Yesterday' : r === 'all' ? 'All' : r === 'custom' ? 'From…to' : `${r} d`}</button>
		{/each}
	</div>
	{#if range === 'custom'}
		<label class="small">from <input type="date" value={span.from} onchange={(e) => setParams({ from: e.currentTarget.value })} /></label>
		<label class="small">to <input type="date" value={addDays(span.to, -1)} onchange={(e) => setParams({ to: e.currentTarget.value })} /></label>
	{/if}
	<div class="seg" role="group" aria-label="Split by">
		<button class:on={by === 'root'} onclick={() => setParams({ by: '' })}>By project / top task</button>
		<button class:on={by === 'task'} onclick={() => setParams({ by: 'task' })}>By exact task</button>
	</div>
	<span class="muted small">{span.from}{addDays(span.to, -1) !== span.from ? ` – ${addDays(span.to, -1)}` : ''} · {fmt(grand)} active in total</span>
</div>
{#if error}<p class="error">{error}</p>{/if}

<div class="legend">
	{#each series as s (s)}<span class="item"><span class="sw" style="background:{color(s)}"></span>{label(s)}</span>{/each}
</div>

<div class="chart panel" role="group" aria-label="active time per agent" bind:this={wrap} onpointerleave={() => (tip = null)}>
	{#if loading && !rows.length}<p class="muted pad">loading…</p>
	{:else if !agents.length}<p class="muted pad">No activity reported in this period. Watchers older than v16 don't report it.</p>{/if}
	{#each agents as a (a.handle)}
		<div class="arow" class:sel={selAgent === a.handle}>
			<button class="who link" onclick={() => setParams({ agent: selAgent === a.handle ? '' : a.handle })}>{a.handle}</button>
			<div class="bar" role="img" aria-label="{a.handle}: {fmt(a.total)} active">
				{#each series.filter((s) => a.by.has(s)) as s (s)}
					{@const v = a.by.get(s) ?? 0}
					<span class="segm" role="presentation" style="width:{(v / maxTotal) * 100}%; background:{color(s)}"
						onpointermove={(e) => hover(e, a.handle, [{ k: s, v }])}></span>
				{/each}
			</div>
			<span class="num">{fmt(a.total)}</span>
			<span class="num muted">{a.periods} periods</span>
		</div>
	{/each}
	{#if tip}
		<div class="tip" style="left:{Math.min(tip.x + 12, (wrap?.clientWidth ?? 600) - 220)}px; top:{tip.y + 12}px">
			<div class="tday">{tip.who}</div>
			{#each tip.html as t (t.k)}<div class="trow"><span class="sw" style="background:{color(t.k)}"></span>{label(t.k)}<b>{fmt(t.v)}</b></div>{/each}
		</div>
	{/if}
</div>

{#if selAgent}
	<section class="detail">
		<h2>{selAgent} <a class="small" href="/agents#{selAgent}">profile</a></h2>
		{#if days.length > 1}
			<div class="days panel" role="img" aria-label="{selAgent}: active time per day">
				{#each days as d (d)}
					{@const dm = daily.get(d)}
					{@const tot = [...(dm?.values() ?? [])].reduce((a, b) => a + b, 0)}
					<div class="dcol" title="{d}: {fmt(tot)}">
						<div class="stack" style="height:{H}px">
							{#each series.filter((s) => dm?.has(s)) as s (s)}
								<span style="height:{((dm!.get(s) ?? 0) / dayMax) * H}px; background:{color(s)}" title="{d} · {label(s)}: {fmt(dm!.get(s) ?? 0)}"></span>
							{/each}
						</div>
						<span class="dl">{days.length <= 14 || d.endsWith('01') || d.endsWith('15') ? d.slice(5) : ''}</span>
					</div>
				{/each}
			</div>
		{/if}

		<h3>By task</h3>
		<table>
			<thead><tr><th>Task / thread</th><th>Active</th><th>Share</th></tr></thead>
			<tbody>
				{#each agentTargets as [t, v] (t)}
					{@const l = targetLabel(t)}
					{@const tot = agentTargets.reduce((s, x) => s + x[1], 0)}
					<tr><td>{#if l.href}<a href={l.href}>{l.text}</a>{:else}<span class="muted">{l.text}</span>{/if}</td><td>{fmt(v)}</td><td>{Math.round((v / tot) * 100)}%</td></tr>
				{/each}
			</tbody>
		</table>

		<h3>Periods <span class="muted small">{periods.length}</span></h3>
		<ul class="periods">
			{#each shownPeriods as p, i (p.started)}
				{#if i === 0 || pDay(p.started) !== pDay(shownPeriods[i - 1].started)}<li class="dayhead">{pDay(p.started)}</li>{/if}
				<li>
					<span class="mono">{hhmm(p.started)}–{hhmm(p.ended)}</span>
					<span class="num">{fmt(p.minutes)}</span>
					{#if p.drivers.length}<span class="muted small">by {p.drivers.join(', ')}</span>{/if}
					<span class="chips">
						{#each p.targets.slice(0, 6) as t (t.target)}
							{@const l = targetLabel(t.target)}
							{#if l.href}<a class="chip" href={l.href} title="{fmt(Number(t.minutes))}"><span class="sw" style="background:{color(seriesOf(keyOf(t.target)))}"></span>{l.text}</a>
							{:else}<span class="chip muted">{l.text}</span>{/if}
						{/each}
						{#if p.targets.length > 6}<span class="muted small">+{p.targets.length - 6}</span>{/if}
					</span>
				</li>
			{/each}
		</ul>
		{#if periods.length > 60 && !showAll}<button class="link" onclick={() => (showAll = true)}>show all {periods.length}</button>{/if}
	</section>
{/if}

<style>
	:global(:root) {
		--s1: #2a78d6; --s2: #eb6834; --s3: #1baf7a; --s4: #eda100; --s5: #e87ba4; --s6: #008300; --s7: #6250d6; --s8: #e34948;
		--s-other: #a3a29c; --s-none: #d6d5cf; --s-thread: #8fb3c9;
	}
	@media (prefers-color-scheme: dark) {
		:global(:root) {
			--s1: #3987e5; --s2: #d95926; --s3: #199e70; --s4: #c98500; --s5: #d55181; --s6: #008300; --s7: #9085e9; --s8: #e66767;
			--s-other: #6b6b66; --s-none: #4a4a46; --s-thread: #4f7389;
		}
	}
	.head { display: flex; gap: 1rem; align-items: baseline; flex-wrap: wrap; margin-bottom: 0.6rem; }
	.head h1 { margin: 0; }
	.controls { display: flex; flex-wrap: wrap; gap: 0.6rem 1rem; align-items: center; margin-bottom: 0.8rem; }
	.seg { display: inline-flex; border: 1px solid var(--line); border-radius: 6px; overflow: hidden; flex-wrap: wrap; }
	.seg button { background: var(--panel); color: var(--muted); border: 0; border-radius: 0; padding: 0.3rem 0.7rem; font-weight: 500; font-size: 0.88rem; }
	.seg button + button { border-left: 1px solid var(--line); }
	.seg button.on { background: var(--accent-soft); color: var(--ink); }
	.small { font-size: 0.8rem; }
	.pad { padding: 0.8rem; }
	.legend { display: flex; flex-wrap: wrap; gap: 0.3rem 0.9rem; margin-bottom: 0.5rem; font-size: 0.85rem; }
	.legend .item { display: inline-flex; gap: 0.35rem; align-items: center; }
	.sw { width: 10px; height: 10px; border-radius: 3px; display: inline-block; flex: none; }
	.panel { background: var(--panel); border: 1px solid var(--line); border-radius: 8px; }
	.chart { position: relative; padding: 0.5rem 0.7rem; display: grid; gap: 0.35rem; }
	.arow { display: grid; grid-template-columns: minmax(6rem, 10rem) 1fr 4rem 6rem; gap: 0.6rem; align-items: center; }
	.arow.sel .who { font-weight: 700; }
	.who { text-align: left; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
	.bar { display: flex; gap: 2px; height: 16px; }
	.segm { display: block; height: 100%; min-width: 2px; }
	.segm:last-child { border-radius: 0 4px 4px 0; }
	.num { font-family: var(--mono); font-size: 0.82rem; text-align: right; white-space: nowrap; }
	button.link { background: none; border: 0; padding: 0; color: var(--accent); font-weight: 500; cursor: pointer; }
	.tip { position: absolute; pointer-events: none; background: var(--panel); border: 1px solid var(--line); border-radius: 6px;
		padding: 0.4rem 0.55rem; font-size: 0.8rem; box-shadow: 0 4px 14px rgb(0 0 0 / 0.15); min-width: 200px; z-index: 2; }
	.tday { font-weight: 600; margin-bottom: 0.2rem; }
	.trow { display: flex; gap: 0.4rem; align-items: center; }
	.trow b { margin-left: auto; font-weight: 500; font-family: var(--mono); }
	.detail h2 { font-size: 1.1rem; margin: 1.3rem 0 0.5rem; }
	.detail h3 { font-size: 0.95rem; margin: 1rem 0 0.4rem; }
	.days { display: flex; gap: 2px; align-items: flex-end; padding: 0.5rem; overflow-x: auto; }
	.dcol { display: grid; justify-items: center; gap: 0.2rem; flex: 1 0 14px; max-width: 40px; }
	.stack { display: flex; flex-direction: column-reverse; gap: 1px; width: 100%; }
	.stack span { display: block; width: 100%; }
	.stack span:last-child { border-radius: 4px 4px 0 0; }
	.dl { font-size: 0.65rem; color: var(--muted); font-family: var(--mono); height: 0.9rem; }
	table { border-collapse: collapse; font-size: 0.82rem; width: 100%; max-width: 760px; }
	th, td { padding: 0.2rem 0.5rem; border-bottom: 1px solid var(--line); text-align: right; }
	th:first-child, td:first-child { text-align: left; }
	.periods { list-style: none; padding: 0; margin: 0; font-size: 0.85rem; }
	.periods li { display: flex; flex-wrap: wrap; gap: 0.2rem 0.7rem; align-items: baseline; padding: 0.25rem 0; border-bottom: 1px solid var(--line); }
	.periods li.dayhead { font-weight: 600; border-bottom: 0; padding-top: 0.7rem; }
	.chips { display: flex; flex-wrap: wrap; gap: 0.3rem; }
	.chip { display: inline-flex; gap: 0.3rem; align-items: center; font-size: 0.78rem; }
	@media (max-width: 600px) {
		.arow { grid-template-columns: 6rem 1fr 3.5rem; }
		.arow .num.muted { display: none; }
	}
</style>
