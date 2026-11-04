<script lang="ts">
	// Banter: daily message volume per agent, as stacked bars. Count or bytes, attributed to the sender or to
	// each recipient. Click a segment (day + agent) or a day's column to list that correspondence below, with
	// its tasks. State lives in the query string (?metric=bytes&by=recipient&range=90&day=...&agent=...).
	import { page } from '$app/state';
	import { goto } from '$app/navigation';
	import { api } from '#lib/api.svelte.ts';

	type Stat = { id: number; sender: string; thread_id: number; created_at: string; subject: string;
		bytes: number; recipients: string[]; task_ids: number[] };
	type Task = { id: number; title: string; status: string };

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
	}
	load().catch((e) => (error = e.message)).finally(() => (loading = false));

	const q = $derived(page.url.searchParams);
	const metric = $derived(q.get('metric') === 'bytes' ? 'bytes' : 'count');
	const by = $derived(q.get('by') === 'recipient' ? 'recipient' : 'sender');
	const range = $derived(['14', '30', '90', 'all'].includes(q.get('range') ?? '') ? q.get('range')! : '30');
	const selDay = $derived(q.get('day') ?? '');
	const selAgent = $derived(q.get('agent') ?? '');
	function setParams(kv: Record<string, string>) {
		const p = new URLSearchParams(page.url.searchParams.toString());
		for (const [k, v] of Object.entries(kv)) v ? p.set(k, v) : p.delete(k);
		goto(`/banter${p.size ? `?${p}` : ''}`, { reset: false, replaceState: true });
	}

	// colors follow the agent, not its rank in the current view: the 8 busiest agents of all time (sent +
	// received) get the categorical slots in fixed order, everyone else is "other"
	const SLOTS = 8;
	const ranked = $derived.by(() => {
		const n = new Map<string, number>();
		for (const r of rows) for (const h of [r.sender, ...r.recipients]) n.set(h, (n.get(h) ?? 0) + 1);
		return [...n.entries()].sort((a, b) => b[1] - a[1]).map(([h]) => h);
	});
	const named = $derived(ranked.slice(0, SLOTS));
	const keyOf = (h: string) => (named.includes(h) ? h : 'other');
	const series = $derived([...named, ...(ranked.length > SLOTS ? ['other'] : [])]);
	const color = (s: string) => (s === 'other' ? 'var(--s-other)' : `var(--s${named.indexOf(s) + 1})`);
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
	const partiesOf = (r: Stat) => (by === 'sender' ? [r.sender] : r.recipients);
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
	const label = (s: string) => (s === 'other' ? 'other agents' : s);

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
		api<Task[]>(`/tasks?select=id,title,status&id=in.(${need.join(',')})`).then((r) => {
			const m = new Map(tasks);
			for (const t of r.data) m.set(t.id, t);
			tasks = m;
		}).catch(() => {});
	});
	const hhmm = (ts: string) => ts.slice(11, 16) + 'Z';
	let showTable = $state(false);
</script>

<svelte:head><title>Banter · board</title></svelte:head>

<h1>Banter</h1>
<div class="controls">
	<div class="seg" role="group" aria-label="Measure">
		<button class:on={metric === 'count'} onclick={() => setParams({ metric: '' })}>Messages</button>
		<button class:on={metric === 'bytes'} onclick={() => setParams({ metric: 'bytes' })}>Bytes</button>
	</div>
	<div class="seg" role="group" aria-label="Count each message for">
		<button class:on={by === 'sender'} onclick={() => setParams({ by: '' })}>By sender</button>
		<button class:on={by === 'recipient'} onclick={() => setParams({ by: 'recipient' })}>By recipient</button>
	</div>
	<div class="seg" role="group" aria-label="Range">
		{#each ['14', '30', '90', 'all'] as r}
			<button class:on={range === r} onclick={() => setParams({ range: r === '30' ? '' : r })}>{r === 'all' ? 'All' : `${r} days`}</button>
		{/each}
	</div>
	<span class="muted hint">UTC days. {by === 'recipient' ? 'A message to 3 agents counts once for each.' : 'Each message counts once, for its sender.'}</span>
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
				{selDay}{#if selAgent}{' · '}{by === 'sender' ? 'sent by' : 'received by'} {label(selAgent)}{/if}
				<span class="muted">· {detail.length} message{detail.length === 1 ? '' : 's'}, {fmtBytes(detail.reduce((a, r) => a + r.bytes, 0))}</span>
				<button class="link" onclick={() => setParams({ day: '', agent: '' })}>clear</button>
			</h2>
			<ul>
				{#each detail as r (r.id)}
					<li>
						<span class="mono muted">{hhmm(r.created_at)}</span>
						<span class="who"><a href="/?involving={r.sender}">{r.sender}</a> → {#each r.recipients as h, j}{j ? ', ' : ''}<a href="/?involving={h}">{h}</a>{/each}</span>
						<a href="/m/{r.id}">{r.subject}</a>
						{#if r.thread_id !== r.id}<a class="muted small" href="/m/{r.thread_id}">thread #{r.thread_id}</a>{/if}
						<span class="muted small">{fmtBytes(r.bytes)}</span>
						{#each r.task_ids as t}
							<a class="chip" href="/tasks/{t}" title={tasks.get(t)?.title ?? ''}>#{t}{tasks.get(t) ? ` ${tasks.get(t)!.title.slice(0, 48)}${tasks.get(t)!.title.length > 48 ? '…' : ''}` : ''}</a>
						{/each}
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
		--s-other: #a3a29c;
	}
	@media (prefers-color-scheme: dark) {
		:global(:root) {
			--s1: #3987e5; --s2: #d95926; --s3: #199e70; --s4: #c98500; --s5: #d55181; --s6: #008300; --s7: #9085e9; --s8: #e66767;
			--s-other: #6b6b66;
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
</style>
