// the signed-in person's current auth token (15 min, refreshed server-side through auth) for the client-rendered UI
// and /claude. Never cached.
import { json } from '@sveltejs/kit';
import type { RequestHandler } from './$types';

export const GET: RequestHandler = ({ locals }) =>
	json({ token: locals.auth?.token ?? null }, { headers: { 'Cache-Control': 'no-store' } });
