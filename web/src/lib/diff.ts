// Small dependency-free text diff for doc revisions: line-level LCS, with word-level
// highlights inside changed line pairs. Docs are at most a few thousand lines; the common
// prefix/suffix is trimmed first, so the O(n*m) table only covers the changed middle.

export type Op = 'eq' | 'del' | 'add';
export type Seg = { op: Op; text: string };
export type Row = { op: Op; a?: number; b?: number; text: string; segs?: Seg[] };

function lcsOps<T>(a: T[], b: T[]): Op[] {
	const n = a.length, m = b.length;
	let pre = 0;
	while (pre < n && pre < m && a[pre] === b[pre]) pre++;
	let suf = 0;
	while (suf < n - pre && suf < m - pre && a[n - 1 - suf] === b[m - 1 - suf]) suf++;
	const A = a.slice(pre, n - suf), B = b.slice(pre, m - suf);
	const N = A.length, M = B.length;
	const ops: Op[] = Array(pre).fill('eq');
	if (N * M > 25_000_000) {
		// too big to align: show the middle as one replaced block
		ops.push(...Array(N).fill('del'), ...Array(M).fill('add'));
	} else {
		const w = M + 1;
		const t = new Uint32Array((N + 1) * w);
		for (let i = N - 1; i >= 0; i--)
			for (let j = M - 1; j >= 0; j--)
				t[i * w + j] = A[i] === B[j] ? t[(i + 1) * w + j + 1] + 1 : Math.max(t[(i + 1) * w + j], t[i * w + j + 1]);
		let i = 0, j = 0;
		while (i < N && j < M) {
			if (A[i] === B[j]) { ops.push('eq'); i++; j++; }
			else if (t[(i + 1) * w + j] >= t[i * w + j + 1]) { ops.push('del'); i++; }
			else { ops.push('add'); j++; }
		}
		while (i++ < N) ops.push('del');
		while (j++ < M) ops.push('add');
	}
	for (let k = 0; k < suf; k++) ops.push('eq');
	return ops;
}

const tokens = (s: string) => s.match(/\s+|[\p{L}\p{N}_]+|[^\s\p{L}\p{N}_]/gu) ?? [];

/** Word-level diff of one changed line pair: segments for the old and the new side. */
export function wordDiff(a: string, b: string): { a: Seg[]; b: Seg[] } {
	const ta = tokens(a), tb = tokens(b);
	const ops = lcsOps(ta, tb);
	const sa: Seg[] = [], sb: Seg[] = [];
	const push = (arr: Seg[], op: Op, text: string) => {
		const last = arr[arr.length - 1];
		if (last && last.op === op) last.text += text; else arr.push({ op, text });
	};
	let i = 0, j = 0;
	for (const op of ops) {
		if (op === 'eq') { push(sa, 'eq', ta[i++]); push(sb, 'eq', tb[j++]); }
		else if (op === 'del') push(sa, 'del', ta[i++]);
		else push(sb, 'add', tb[j++]);
	}
	return { a: sa, b: sb };
}

/** Line diff of two texts. Changed runs pair their del/add lines for word highlights. */
export function diffLines(oldText: string, newText: string): Row[] {
	const a = oldText.replace(/\r\n/g, '\n').split('\n');
	const b = newText.replace(/\r\n/g, '\n').split('\n');
	const ops = lcsOps(a, b);
	const rows: Row[] = [];
	let i = 0, j = 0, k = 0;
	while (k < ops.length) {
		if (ops[k] === 'eq') { rows.push({ op: 'eq', a: i + 1, b: j + 1, text: a[i] }); i++; j++; k++; continue; }
		const dels: Row[] = [], adds: Row[] = [];
		while (k < ops.length && ops[k] !== 'eq') {
			if (ops[k] === 'del') { dels.push({ op: 'del', a: i + 1, text: a[i] }); i++; }
			else { adds.push({ op: 'add', b: j + 1, text: b[j] }); j++; }
			k++;
		}
		for (let p = 0; p < Math.min(dels.length, adds.length); p++) {
			// only highlight words when the lines are still recognisably the same line
			const wd = wordDiff(dels[p].text, adds[p].text);
			const same = wd.a.filter((s) => s.op === 'eq').reduce((n, s) => n + s.text.length, 0);
			if (same * 2 >= Math.max(dels[p].text.length, adds[p].text.length) * 0.6) { dels[p].segs = wd.a; adds[p].segs = wd.b; }
		}
		rows.push(...dels, ...adds);
	}
	return rows;
}

export type Hunk = { rows: Row[] } | { skip: Row[] };

/** Group rows into hunks: changes with `ctx` lines of context, long unchanged runs folded. */
export function hunks(rows: Row[], ctx = 3): Hunk[] {
	const keep = new Uint8Array(rows.length);
	rows.forEach((r, k) => {
		if (r.op !== 'eq') for (let d = Math.max(0, k - ctx); d <= Math.min(rows.length - 1, k + ctx); d++) keep[d] = 1;
	});
	const out: Hunk[] = [];
	let k = 0;
	while (k < rows.length) {
		const start = k, kept = keep[k];
		while (k < rows.length && keep[k] === kept) k++;
		const run = rows.slice(start, k);
		out.push(kept ? { rows: run } : { skip: run });
	}
	return out;
}

export const stats = (rows: Row[]) => ({
	add: rows.filter((r) => r.op === 'add').length,
	del: rows.filter((r) => r.op === 'del').length,
});
