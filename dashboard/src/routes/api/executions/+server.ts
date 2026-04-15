import { json } from '@sveltejs/kit';
import type { RequestEvent } from '@sveltejs/kit';
import * as db from '$lib/server/db';
import { requireUserId } from '$lib/server/auth-locals';

export const GET = async (event: RequestEvent) => {
	// Always scope to the authenticated caller. Previously this read
	// userId from a query param, which let any client pass any
	// userId and read another user's execution history.
	const userId = requireUserId(event);
	try {
		await db.initDb();
		const projectId = event.url.searchParams.get('projectId') || undefined;
		const limit = parseInt(event.url.searchParams.get('limit') || '50', 10);
		const offset = parseInt(event.url.searchParams.get('offset') || '0', 10);

		const executions = await db.listExecutions(projectId, userId, limit, offset);
		return json(executions);
	} catch (error) {
		console.error('Failed to list executions:', error);
		return json({ error: 'Failed to list executions' }, { status: 500 });
	}
};

export const POST = async (event: RequestEvent) => {
	// Owner is the authenticated caller. The previous version
	// trusted `body.userId` which let any client claim to own any
	// execution. The body's userId field is now ignored.
	const userId = requireUserId(event);
	try {
		await db.initDb();
		const body = await event.request.json();
		const { id, projectId, triggerId, nodeType } = body;

		if (!id || !projectId) {
			return json({ error: 'id and projectId are required' }, { status: 400 });
		}

		// Confirm the project belongs to the caller before creating
		// an execution row. Without this check, a caller could
		// create execution rows attributed to themselves but
		// pointing at another user's project, polluting that user's
		// execution history visible via the join.
		const project = await db.getProject(projectId, userId);
		if (!project) {
			return json({ error: 'Project not found' }, { status: 404 });
		}

		const execution = await db.createExecution(
			id,
			projectId,
			userId,
			triggerId,
			nodeType
		);

		// Record execution usage event for cost tracking
		await db.recordUsageEvent(userId, 'execution', projectId, id);

		return json(execution, { status: 201 });
	} catch (error) {
		console.error('Failed to create execution:', error);
		return json({ error: 'Failed to create execution' }, { status: 500 });
	}
};
