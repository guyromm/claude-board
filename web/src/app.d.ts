// See https://svelte.dev/docs/kit/types#app.d.ts
// for information about these interfaces
declare global {
	namespace App {
		// interface Error {}
		interface Locals {
			// set by hooks.server.ts on /auth/* (auth.webgma.co.il sign-in, #275/5)
			auth: { user: { id: string; username: string; name: string }; role: string; sid: string; token: string } | null;
		}
		// interface PageData {}
		// interface PageState {}
		// interface Platform {}
	}
}

export {};
