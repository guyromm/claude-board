// Text anchoring for doc comments: find a quoted passage in rendered HTML (whitespace-normalised,
// disambiguated by the text just before it) and wrap it in <mark> elements, one per text node.

type Pos = { node: Text; off: number };
type Index = { text: string; map: Pos[] };

export const norm = (s: string) => s.replace(/\s+/g, ' ');

function index(root: Node): Index {
	const map: Pos[] = [];
	let text = '';
	const w = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
	for (let n = w.nextNode() as Text | null; n; n = w.nextNode() as Text | null) {
		const s = n.data;
		for (let i = 0; i < s.length; i++) {
			const ws = /\s/.test(s[i]);
			if (ws && (text === '' || text.endsWith(' '))) continue;
			text += ws ? ' ' : s[i];
			map.push({ node: n, off: i });
		}
	}
	return { text, map };
}

/** Normalised text of everything in `root` before / after a range (for prefix/suffix context). */
export function context(root: Node, r: Range, len = 64): { prefix: string; suffix: string } {
	const before = document.createRange(); before.selectNodeContents(root); before.setEnd(r.startContainer, r.startOffset);
	const after = document.createRange(); after.selectNodeContents(root); after.setStart(r.endContainer, r.endOffset);
	return { prefix: norm(before.toString()).slice(-len), suffix: norm(after.toString()).slice(0, len) };
}

/** Find the quote; returns [start, end) in the index, or null. */
function locate(ix: Index, quote: string, prefix: string): [number, number] | null {
	const q = norm(quote).trim();
	if (!q) return null;
	const hits: number[] = [];
	for (let i = ix.text.indexOf(q); i >= 0; i = ix.text.indexOf(q, i + 1)) hits.push(i);
	if (!hits.length) return null;
	const p = norm(prefix).trim();
	const best = (p ? hits.find((i) => ix.text.slice(0, i).trimEnd().endsWith(p.slice(-24))) : undefined) ?? hits[0];
	return [best, best + q.length];
}

/** Wrap the quote in <mark class="cmt" data-cid=id>. Returns the first mark, or null if not found. */
export function highlight(root: HTMLElement, quote: string, prefix: string, id: number): HTMLElement | null {
	const ix = index(root);
	const at = locate(ix, quote, prefix);
	if (!at) return null;
	const [s, e] = at;
	// group the covered characters by text node: node -> [first raw offset, last raw offset + 1]
	const spans = new Map<Text, [number, number]>();
	for (let k = s; k < e; k++) {
		const { node, off } = ix.map[k];
		const cur = spans.get(node);
		spans.set(node, cur ? [cur[0], off + 1] : [off, off + 1]);
	}
	let first: HTMLElement | null = null;
	for (const [node, [a, b]] of spans) {
		if (!node.parentNode || /^(script|style)$/i.test(node.parentNode.nodeName)) continue;
		const mid = a > 0 ? node.splitText(a) : node;
		if (b - a < mid.data.length) mid.splitText(b - a);
		const m = document.createElement('mark');
		m.className = 'cmt';
		m.dataset.cid = String(id);
		mid.parentNode!.replaceChild(m, mid);
		m.appendChild(mid);
		first ??= m;
	}
	return first;
}

/** All comment ids on a mark and its enclosing marks (overlapping comments nest). */
export function idsAt(el: Element | null): number[] {
	const out: number[] = [];
	for (let m = el?.closest('mark.cmt'); m; m = m.parentElement?.closest('mark.cmt') ?? null) {
		const id = Number((m as HTMLElement).dataset.cid);
		if (!out.includes(id)) out.push(id);
	}
	return out;
}

/** One source line (Markdown or org) reduced to roughly the text it renders as, so passages selected in
 *  the source (diff view) match passages selected on the rendered page, and the other way round. */
export function stripLine(line: string, format: 'md' | 'org' | string): string {
	let s = line;
	if (/^\s*(```|~~~|#\+(begin|end)_\w+)/i.test(s)) return '';
	if (/^\s*\|?[\s:|+-]*-{3,}[\s:|+-]*\|?\s*$/.test(s)) return ''; // table rule
	s = s.replace(/^\s*#\+\w+:\s*/i, ''); // org keyword (#+TITLE: x)
	s = format === 'org' ? s.replace(/^\s*\*+\s+/, '') : s.replace(/^\s{0,3}#{1,6}\s+/, '');
	s = s.replace(/^\s*(>\s*)+/, '').replace(/^\s*([-+*]|\d+[.)])\s+(\[[ xX-]\]\s+)?/, '');
	s = s.replace(/!\[([^\]]*)\]\([^)]*\)/g, '$1').replace(/\[([^\]]+)\]\([^)]*\)/g, '$1'); // md images/links
	s = s.replace(/\[\[([^\]]+)\]\[([^\]]+)\]\]/g, '$2').replace(/\[\[([^\]]+)\]\]/g, '$1'); // org links
	s = s.replace(/\*\*|__|~~|`/g, '');
	s = s.replace(/(^|[\s(["'])[*=~+/]+(?=\S)/g, '$1').replace(/(?<=\S)[*=~+/]+(?=[\s)\]"'.,;:!?]|$)/g, '');
	s = s.replace(/\s*\|\s*/g, ' ');
	return s;
}

/** A whole source text as stripped, whitespace-normalised text, with the line each character came from. */
export function strippedText(src: string, format: string): { text: string; line: number[] } {
	let text = '';
	const line: number[] = [];
	src.replace(/\r\n/g, '\n').split('\n').forEach((raw, i) => {
		const t = norm(stripLine(raw, format)).trim();
		if (!t) return;
		if (text) { text += ' '; line.push(i + 1); }
		for (const ch of t) { text += ch; line.push(i + 1); }
	});
	return { text, line };
}

/** Lines (1-based) of `src` covered by the quote, picking the hit nearest `nearLine` or matching `prefix`. */
export function quoteLines(src: string, format: string, quote: string, prefix = '', nearLine?: number):
	{ lines: number[]; prefix: string; suffix: string } | null {
	const { text, line } = strippedText(src, format);
	const q = norm(quote).trim();
	if (!q) return null;
	const hits: number[] = [];
	for (let i = text.indexOf(q); i >= 0; i = text.indexOf(q, i + 1)) hits.push(i);
	if (!hits.length) return null;
	const p = norm(prefix).trim().slice(-24);
	let at = hits[0];
	if (nearLine !== undefined) at = hits.reduce((b, h) => (Math.abs(line[h] - nearLine) < Math.abs(line[b] - nearLine) ? h : b), hits[0]);
	else if (p) at = hits.find((h) => text.slice(0, h).trimEnd().endsWith(p)) ?? hits[0];
	const lines: number[] = [];
	for (let k = line[at]; k <= line[at + q.length - 1]; k++) lines.push(k);
	return { lines, prefix: text.slice(Math.max(0, at - 64), at), suffix: text.slice(at + q.length, at + q.length + 64) };
}
