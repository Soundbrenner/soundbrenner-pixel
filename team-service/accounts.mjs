export const monthlyLimit = 1000;
const sessionLifetime = 30 * 24 * 60 * 60 * 1000;
const spendLimit = { threshold_amount: monthlyLimit, currency: 'USD', interval: 'month' };
const upstreamOrigin = 'https://api.openai.com';
const authOrigin = 'https://showtime.soundbrenner.com';
const encoder = new TextEncoder();

export class ServiceError extends Error {
    constructor(status, message) {
        super(message);
        this.status = status;
    }
}

export const json = (body, status = 200) => Response.json(body, { status, headers: { 'Cache-Control': 'no-store' } });
export const errorResponse = error => error instanceof ServiceError
    ? json({ error: { message: error.message } }, error.status)
    : json({ error: { message: 'Mediaforge team service is temporarily unavailable.' } }, 503);

export async function hash(value) {
    return bytesToHex(new Uint8Array(await crypto.subtle.digest('SHA-256', encoder.encode(value))));
}

function bytesToHex(bytes) {
    return Array.from(bytes, byte => byte.toString(16).padStart(2, '0')).join('');
}

async function secretKey(env) {
    const bytes = Uint8Array.from(atob(env.ACCOUNT_STORAGE_KEY), character => character.charCodeAt(0));
    if (bytes.length !== 32) throw new ServiceError(503, 'Mediaforge team access is not configured.');
    return crypto.subtle.importKey('raw', bytes, 'AES-GCM', false, ['encrypt', 'decrypt']);
}

async function seal(env, scope, value) {
    const key = await secretKey(env);
    const iv = crypto.getRandomValues(new Uint8Array(12));
    const encrypted = new Uint8Array(await crypto.subtle.encrypt(
        { name: 'AES-GCM', iv, additionalData: encoder.encode(scope) }, key, encoder.encode(value),
    ));
    return [iv, encrypted].map(bytes => btoa(String.fromCharCode(...bytes))).join('.');
}

async function unseal(env, scope, value) {
    const key = await secretKey(env);
    const [iv, ciphertext] = value.split('.').map(part => Uint8Array.from(atob(part), character => character.charCodeAt(0)));
    const plaintext = await crypto.subtle.decrypt(
        { name: 'AES-GCM', iv, additionalData: encoder.encode(scope) }, key, ciphertext,
    );
    return new TextDecoder().decode(plaintext);
}

function authRequest(env, path, options) {
    return env.AUTH.fetch(new Request(authOrigin + path, {
        ...options, signal: AbortSignal.timeout(20_000), redirect: 'manual',
    }));
}

export async function verifyIdentity(env, token) {
    const response = await authRequest(env, '/api/me', { headers: { Authorization: 'Bearer ' + token } });
    if ([401, 403].includes(response.status)) {
        throw new ServiceError(401, 'Your Soundbrenner session has expired. Sign in again.');
    }
    if (!response.ok) throw new ServiceError(503, 'Soundbrenner sign-in is temporarily unavailable.');
    const { id, name } = await response.json();
    if (typeof id !== 'string' || id.length === 0 || id.length > 128 || typeof name !== 'string') {
        throw new ServiceError(503, 'Soundbrenner returned an invalid account.');
    }
    return { id, name };
}

export async function login(env, email, password) {
    const response = await authRequest(env, '/api/login', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ email, password }),
    });
    if (response.status === 429) throw new ServiceError(429, 'Too many sign-in attempts. Try again shortly.');
    if (response.status === 403) throw new ServiceError(403, 'Use an approved Soundbrenner account with a verified email.');
    if (response.status === 401) throw new ServiceError(401, 'Check your Soundbrenner email and password.');
    if (!response.ok) throw new ServiceError(503, 'Soundbrenner sign-in is temporarily unavailable.');
    const result = await response.json();
    if (typeof result.token !== 'string' || !result.token) {
        throw new ServiceError(503, 'Soundbrenner returned an invalid session.');
    }
    const identity = await verifyIdentity(env, result.token);
    if (identity.id !== result.member?.id) throw new ServiceError(503, 'Soundbrenner account verification failed.');
    return { identity, identityToken: result.token };
}

async function admin(env, transport, path, body) {
    if (!env.OPENAI_ADMIN_KEY) throw new ServiceError(503, 'Mediaforge team billing is not configured.');
    const response = await transport(upstreamOrigin + '/v1/organization/projects' + path, {
        method: body === undefined ? 'GET' : 'POST',
        headers: {
            Authorization: 'Bearer ' + env.OPENAI_ADMIN_KEY,
            'Content-Type': 'application/json',
        },
        body: body === undefined ? undefined : JSON.stringify(body),
        signal: AbortSignal.timeout(20_000),
        redirect: 'manual',
    });
    if (!response.ok) throw new ServiceError(503, 'Mediaforge could not configure your OpenAI project. Try again shortly.');
    return response.json();
}

async function findNamed(env, transport, root, name) {
    let after;
    do {
        const query = new URLSearchParams({ limit: '100' });
        if (after) query.set('after', after);
        const page = await admin(env, transport, root + '?' + query);
        if (!Array.isArray(page.data)) throw new ServiceError(503, 'Mediaforge could not verify OpenAI provisioning.');
        const match = page.data.find(item => item.name === name);
        if (match) return match;
        if (!page.has_more) return null;
        if (!page.last_id || page.last_id === after) throw new ServiceError(503, 'Mediaforge could not read OpenAI projects.');
        after = page.last_id;
    } while (after);
    return null;
}

async function createOrRecover(env, transport, storage, route, name, slot, options = {}) {
    const existing = await findNamed(env, transport, route, name);
    if (existing) return existing;
    const previousAttempt = await storage.get(slot);
    if (previousAttempt && Date.now() - previousAttempt < 60_000) {
        throw new ServiceError(503, 'Mediaforge is completing your account setup. Try again shortly.');
    }
    await storage.put(slot, Date.now());
    return admin(env, transport, route, { name, ...options });
}

export class Account {
    constructor(storage, env, id, transport = fetch) {
        this.storage = storage;
        this.env = env;
        this.id = id;
        this.transport = transport;
    }

    async provision(name) {
        if (!this.provisioning) {
            this.provisioning = this.ensureBilling(name).finally(() => { this.provisioning = undefined; });
        }
        return this.provisioning;
    }

    async ensureBilling(name) {
        const { storage, env, transport, id } = this;
        if (!env.OPENAI_ADMIN_KEY) throw new ServiceError(503, 'Mediaforge team billing is not configured.');
        await secretKey(env);
        const billing = await storage.get('billing');
        if (billing?.key && (billing.expiresAt ?? Infinity) > Date.now() + 60_000) return billing;

        let projectId = billing?.projectId;
        if (!projectId) {
            let projectName = await storage.get('project-name');
            if (!projectName) {
                const label = name.replace(/[\x00-\x1f\x7f]/g, ' ').trim().slice(0, 50);
                projectName = `Mediaforge ${label} [${id.slice(0, 16)}]`;
                await storage.put('project-name', projectName);
            }
            const project = await createOrRecover(env, transport, storage, '', projectName, 'project-attempt');
            if (typeof project.id !== 'string' || !project.id) throw new ServiceError(503, 'Could not verify the OpenAI project.');
            projectId = project.id;
            await storage.put('billing', { projectId });
        }

        const route = '/' + encodeURIComponent(projectId);
        const limit = await admin(env, transport, route + '/spend_limit', spendLimit);
        if (limit.threshold_amount !== monthlyLimit || limit.currency !== 'USD'
            || limit.interval !== 'month' || limit.enforcement !== 'hard') {
            throw new ServiceError(503, 'Mediaforge could not verify the $10 monthly spending limit.');
        }
        const accountsRoute = route + '/service_accounts';
        const account = await createOrRecover(
            env, transport, storage, accountsRoute, 'Mediaforge proxy', 'service-account-attempt',
            { expires_in_seconds: 7_776_000 },
        );
        if (typeof account.id !== 'string' || !account.id) throw new ServiceError(503, 'Could not verify the OpenAI service account.');
        const key = account.api_key ?? await admin(env, transport, accountsRoute + '/' + encodeURIComponent(account.id) + '/api_keys', {
            name: 'Mediaforge proxy',
            expires_in_seconds: 7_776_000,
        });
        if (typeof key.value !== 'string' || !key.value) throw new ServiceError(503, 'Could not issue the OpenAI service key.');
        const state = {
            projectId,
            key: await seal(env, id + ':billing', key.value),
            expiresAt: key.expires_at == null ? null : key.expires_at * 1000,
        };
        await storage.put('billing', state);
        return state;
    }

    async createSession(identity, identityToken) {
        // Provisioning returns only after OpenAI has confirmed the spending limit.
        await this.provision(identity.name);
        const secret = bytesToHex(crypto.getRandomValues(new Uint8Array(32)));
        const tokenHash = await hash(secret);
        const expiresAt = Date.now() + sessionLifetime;
        await this.storage.put('session:' + tokenHash, {
            identity,
            identityToken: await seal(this.env, this.id + ':session:' + tokenHash, identityToken),
            expiresAt,
        });
        return { token: `mf.${this.id}.${secret}`, member: identity, expiresAt, monthlyLimitCents: monthlyLimit };
    }

    async session(secret) {
        const tokenHash = await hash(secret);
        const key = 'session:' + tokenHash;
        const session = await this.storage.get(key);
        if (!session || session.expiresAt <= Date.now()) {
            if (session) await this.storage.delete(key);
            throw new ServiceError(401, 'Sign in to Mediaforge again.');
        }
        const upstreamToken = await unseal(this.env, this.id + ':session:' + tokenHash, session.identityToken);
        const identity = await verifyIdentity(this.env, upstreamToken);
        if (identity.id !== session.identity.id) throw new ServiceError(401, 'Soundbrenner account verification failed.');
        return { member: identity, expiresAt: session.expiresAt, monthlyLimitCents: monthlyLimit };
    }

    async logout(secret) {
        await this.storage.delete('session:' + await hash(secret));
    }

    async providerKey(name) {
        const billing = await this.provision(name);
        return unseal(this.env, this.id + ':billing', billing.key);
    }
}
