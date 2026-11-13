// Parse `git diff` (unified) output into files and hunks for the review page.
import { wordDiff, type Seg } from './diff.ts';

export type DLine = { t: ' ' | '+' | '-' | '\\'; old?: number; new?: number; text: string; segs?: Seg[] };
export type DHunk = { header: string; lines: DLine[] };
export type DFile = { oldPath: string; newPath: string; path: string; status: 'modified' | 'added' | 'deleted' | 'renamed';
	binary: boolean; hunks: DHunk[]; adds: number; dels: number; meta: string[] };

const unq = (p: string) => (p.startsWith('"') ? JSON.parse(p) : p);
const strip = (p: string) => (p === '/dev/null' ? p : p.replace(/^[ab]\//, ''));

export function parseDiff(text: string): DFile[] {
	const files: DFile[] = [];
	let f: DFile | null = null, h: DHunk | null = null, o = 0, n = 0;
	for (const line of text.replace(/\r\n/g, '\n').split('\n')) {
		if (line.startsWith('diff --git ')) {
			const m = /^diff --git (".*?"|\S+) (".*?"|\S+)$/.exec(line);
			const a = m ? strip(unq(m[1])) : '', b = m ? strip(unq(m[2])) : '';
			f = { oldPath: a, newPath: b, path: b || a, status: 'modified', binary: false, hunks: [], adds: 0, dels: 0, meta: [] };
			files.push(f); h = null; continue;
		}
		if (!f) continue;
		if (line.startsWith('@@')) {
			const m = /^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@/.exec(line);
			o = m ? Number(m[1]) : 0; n = m ? Number(m[2]) : 0;
			h = { header: line, lines: [] }; f.hunks.push(h); continue;
		}
		if (!h) { // file header lines, before the first hunk
			if (line.startsWith('new file mode')) f.status = 'added';
			else if (line.startsWith('deleted file mode')) f.status = 'deleted';
			else if (line.startsWith('rename from ')) { f.status = 'renamed'; f.oldPath = line.slice(12); }
			else if (line.startsWith('rename to ')) { f.newPath = line.slice(10); f.path = f.newPath; }
			else if (line.startsWith('Binary files ') || line === 'GIT binary patch') f.binary = true;
			else if (line && !/^(index |--- |\+\+\+ |similarity |old mode|new mode)/.test(line)) f.meta.push(line);
			continue;
		}
		if (!line || !/^[ +\-\\]/.test(line)) continue;
		const t = line[0] as DLine['t'];
		const text = line.slice(1);
		if (t === '+') { h!.lines.push({ t, new: n++, text }); f.adds++; }
		else if (t === '-') { h!.lines.push({ t, old: o++, text }); f.dels++; }
		else if (t === ' ') h!.lines.push({ t, old: o++, new: n++, text });
		else if (t === '\\') h!.lines.push({ t, text });
	}
	// word-level highlights for paired -/+ runs
	for (const file of files) for (const hk of file.hunks) {
		const L = hk.lines;
		for (let i = 0; i < L.length; ) {
			if (L[i].t !== '-') { i++; continue; }
			let j = i; while (j < L.length && L[j].t === '-') j++;
			let k = j; while (k < L.length && L[k].t === '+') k++;
			for (let p = 0; p < Math.min(j - i, k - j); p++) {
				const a = L[i + p], b = L[j + p];
				if (a.text.length + b.text.length > 4000) continue;
				const wd = wordDiff(a.text, b.text);
				const same = wd.a.filter((s) => s.op === 'eq').reduce((x, s) => x + s.text.length, 0);
				if (same >= 0.3 * Math.max(a.text.length, b.text.length)) { a.segs = wd.a; b.segs = wd.b; }
			}
			i = k;
		}
	}
	return files;
}
