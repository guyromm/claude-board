import { syncAuth } from '#lib/api.svelte.ts';

// The UI is a client-side app over PostgREST (token in localStorage); only /join, the client
// script routes and /auth/* (auth.webgma.co.il sign-in) run on the server.
export const ssr = false;

// auth.webgma.co.il sign-in (#275/5): pick up the auth session BEFORE the first render, so the layout's
// "no session -> /login" redirect never bounces a signed-in person
export const load = async () => {
	await syncAuth();
	return {};
};
