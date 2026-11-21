import { DurableObject } from 'cloudflare:workers';
import { Account, ServiceError, errorResponse, hash, json, login } from './accounts.mjs';

const imageModels = [
    'gpt-image-2.5-sunburst', 'gpt-image-2.5-flare', 'gpt-image-2',
    'gpt-image-2-2026-04-21', 'gpt-image-1.5', 'gpt-image-1-mini',
];
const visionModels = ['gpt-6-luna', 'gpt-6.2-astra'];
const paidPaths = new Set(['/v1/images/generations', '/v1/images/edits', '/v1/chat/completions']);

async function boundedBody(request, limit) {
    const declared = request.headers.get('Content-Length');
    if (declared && Number(declared) > limit) throw new ServiceError(413, 'This request is too large.');
    if (!request.body) throw new ServiceError(400, 'The request body is missing.');
    const reader = request.body.getReader();
    const chunks = [];
    let remaining = limit;
    while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        remaining -= value.byteLength;
        if (remaining < 0) {
            await reader.cancel();
            throw new ServiceError(413, 'This request is too large.');
        }
        chunks.push(value);
    }
    return new Blob(chunks);
}

async function readJSON(blob) {
    try {
        const data = JSON.parse(await blob.text());
        if (data && typeof data === 'object' && !Array.isArray(data)) return data;
    } catch {
        // Present a stable error instead of exposing the request.
    }
    throw new ServiceError(400, 'Expected a JSON object.');
}

function checkImageRequest(model, count) {
    if (!imageModels.includes(model)) throw new ServiceError(400, 'This image model is unavailable with team billing.');
    if (!Number.isInteger(count) || count < 1 || count > 8) throw new ServiceError(400, 'Choose between one and eight images.');
}

async function generationBody(request, path) {
    const contentType = request.headers.get('Content-Type') ?? '';
    const blob = await boundedBody(request, 24 * 1024 * 1024);
    if (path === '/v1/images/edits') {
        if (!/^multipart\/form-data;/i.test(contentType)) throw new ServiceError(415, 'Expected a multipart image request.');
        let form;
        try {
            form = await new Response(blob, { headers: { 'Content-Type': contentType } }).formData();
        } catch {
            throw new ServiceError(400, 'Could not read the reference images.');
        }
        checkImageRequest(form.get('model'), Number(form.get('n') ?? 1));
        const allowed = new Set(['model', 'n', 'prompt', 'size', 'quality', 'output_format', 'output_compression', 'moderation', 'image[]']);
        if ([...form.keys()].some(field => !allowed.has(field))
            || [...allowed].some(field => field !== 'image[]' && form.getAll(field).length > 1)) {
            throw new ServiceError(400, 'The image request contains unsupported fields.');
        }
        return { body: blob, contentType };
    }
    if (!/^application\/json\b/i.test(contentType)) throw new ServiceError(415, 'Expected a JSON request.');
    const body = await readJSON(blob);
    if (path === '/v1/images/generations') {
        checkImageRequest(body.model, body.n ?? 1);
        const allowed = ['model', 'n', 'prompt', 'size', 'quality', 'output_format', 'output_compression', 'moderation'];
        if (Object.keys(body).some(key => !allowed.includes(key))) {
            throw new ServiceError(400, 'The image request contains unsupported fields.');
        }
    } else {
        if (!visionModels.includes(body.model) || !Array.isArray(body.messages) || body.messages.length !== 2) {
            throw new ServiceError(400, 'This ad review request is unsupported.');
        }
        return {
            body: JSON.stringify({
                model: body.model,
                messages: body.messages,
                response_format: { type: 'json_object' },
                reasoning_effort: 'low',
                max_completion_tokens: 4096,
            }),
            contentType,
        };
    }
    return { body: JSON.stringify(body), contentType };
}

export class MediaforgeAccount extends DurableObject {
    constructor(ctx, env) {
        super(ctx, env);
        this.account = new Account(ctx.storage, env, ctx.id.toString());
    }

    async signIn(identity, identityToken) {
        try {
            return json(await this.account.createSession(identity, identityToken));
        } catch (error) {
            return errorResponse(error);
        }
    }

    async session(secret) {
        try {
            return json(await this.account.session(secret));
        } catch (error) {
            return errorResponse(error);
        }
    }

    async logout(secret) {
        try {
            await this.account.logout(secret);
            return json({ signedOut: true });
        } catch (error) {
            return errorResponse(error);
        }
    }

    async openAI(request, secret) {
        try {
            return await this.#callProvider(request, secret);
        } catch (error) {
            return errorResponse(error);
        }
    }

    async #callProvider(request, secret) {
        const session = await this.account.session(secret);
        const path = new URL(request.url).pathname;
        if (request.method === 'GET' && path === '/v1/models') {
            return json({ data: imageModels.map(id => ({ id })) });
        }
        if (request.method !== 'POST' || !paidPaths.has(path)) return json({ error: { message: 'Route not found.' } }, 404);
        const { success } = await this.env.GENERATION_LIMITER.limit({ key: this.ctx.id.toString() });
        if (!success) throw new ServiceError(429, 'Too many Mediaforge requests. Try again shortly.');
        const { body, contentType } = await generationBody(request, path);
        const key = await this.account.providerKey(session.member.name);
        const provider = await fetch('https://api.openai.com' + path, {
            method: 'POST',
            headers: { Authorization: 'Bearer ' + key, 'Content-Type': contentType },
            body,
            signal: AbortSignal.timeout(1_190_000),
            redirect: 'manual',
        });
        if ((provider.status >= 300 && provider.status < 400) || provider.status === 401 || provider.status === 403) {
            throw new ServiceError(503, 'OpenAI team generation is temporarily unavailable.');
        }
        const headers = { 'Content-Type': provider.headers.get('Content-Type') ?? 'application/json', 'Cache-Control': 'no-store' };
        return new Response(provider.body, { status: provider.status, headers });
    }
}

function bearer(request) {
    const token = /^Bearer mf\.([a-f0-9]{64})\.([a-f0-9]{64})$/.exec(request.headers.get('Authorization') ?? '');
    if (!token) throw new ServiceError(401, 'Sign in to Mediaforge.');
    return { id: token[1], secret: token[2] };
}

export default {
    async fetch(request, env) {
        try {
            const { pathname } = new URL(request.url);
            if (request.method === 'GET' && pathname === '/health') return json({ status: 'ok' });
            if (request.method === 'POST' && pathname === '/account/login') {
                const ip = request.headers.get('CF-Connecting-IP') ?? 'local';
                if (!(await env.LOGIN_LIMITER.limit({ key: 'ip:' + await hash(ip) })).success) {
                    throw new ServiceError(429, 'Too many sign-in attempts. Try again shortly.');
                }
                const { email, password } = await readJSON(await boundedBody(request, 4_096));
                if (typeof email !== 'string' || !email.trim() || email.length > 254 ||
                    typeof password !== 'string' || !password || password.length > 1024) {
                    throw new ServiceError(400, 'Enter your Soundbrenner account email and password.');
                }
                const normalizedEmail = email.trim().toLowerCase();
                if (!(await env.LOGIN_LIMITER.limit({ key: 'account:' + await hash(normalizedEmail) })).success) {
                    throw new ServiceError(429, 'Too many sign-in attempts. Try again shortly.');
                }
                if (!env.OPENAI_ADMIN_KEY || !env.ACCOUNT_STORAGE_KEY) {
                    throw new ServiceError(503, 'Mediaforge team billing is not configured.');
                }
                const { identity, identityToken } = await login(env, normalizedEmail, password);
                return await env.ACCOUNTS.getByName(identity.id).signIn(identity, identityToken);
            }

            const isSession = request.method === 'GET' && pathname === '/account/session';
            const isLogout = request.method === 'POST' && pathname === '/account/logout';
            const isProvider = (request.method === 'GET' && pathname === '/v1/models')
                || (request.method === 'POST' && paidPaths.has(pathname));
            if (!isSession && !isLogout && !isProvider) return json({ error: { message: 'Route not found.' } }, 404);

            const { id, secret } = bearer(request);
            const account = env.ACCOUNTS.get(env.ACCOUNTS.idFromString(id));
            if (isSession) return await account.session(secret);
            if (isLogout) return await account.logout(secret);
            return await account.openAI(request, secret);
        } catch (error) {
            return errorResponse(error);
        }
    },
};
