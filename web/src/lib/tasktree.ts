import type { Task } from '#lib/api.svelte.ts';

// Order a column's tasks so each one follows its nearest ancestor that is in the same column, with its
// depth below that ancestor (any number of levels). Tasks with no ancestor in the column keep their
// order; siblings keep theirs. byId must hold every task (ancestors outside the column included).
export function groupTree(items: Task[], byId: Map<number, Task>): { t: Task; depth: number }[] {
	const here = new Set(items.map((t) => t.id));
	const parentIn = (t: Task) => {
		for (let p = t.parent_id ? byId.get(t.parent_id) : undefined; p; p = p.parent_id ? byId.get(p.parent_id) : undefined)
			if (here.has(p.id)) return p.id;
		return null;
	};
	const kids = new Map<number | null, Task[]>();
	for (const t of items) {
		const p = parentIn(t);
		if (!kids.has(p)) kids.set(p, []);
		kids.get(p)!.push(t);
	}
	const out: { t: Task; depth: number }[] = [];
	const walk = (p: number | null, depth: number) => {
		for (const t of kids.get(p) ?? []) { out.push({ t, depth }); walk(t.id, depth + 1); }
	};
	walk(null, 0);
	return out;
}
