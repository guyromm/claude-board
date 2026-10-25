// route param matchers (SvelteKit 3: one defineParams export; a matcher returns the value, or undefined)
import { defineParams } from '@sveltejs/kit/params';

// /tasks/<status> (todo, doing, ...) vs /tasks/<id>: only a task status matches [status=status]
const STATUSES = ['ongoing', 'todo', 'doing', 'blocked', 'review', 'done', 'cancelled'];

export const params = defineParams({
	status: (param: string) => (STATUSES.includes(param) ? param : undefined)
});
