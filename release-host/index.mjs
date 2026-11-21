export default {
    async fetch(request, env) {
        if (request.method !== 'GET' && request.method !== 'HEAD') {
            return new Response(null, { status: 405, headers: { Allow: 'GET, HEAD' } });
        }

        const path = new URL(request.url).pathname;
        const match = /^\/downloads\/(appcast\.xml|(?:Mediaforge|Pixel)-\d+\.\d+\.\d+-\d+\.(?:zip|dmg))$/.exec(path);
        if (!match) return new Response(null, { status: 404 });

        const name = match[1];
        const object = request.method === 'HEAD' ? await env.RELEASES.head(name) : await env.RELEASES.get(name);
        if (!object) return new Response(null, { status: 404, headers: { 'Cache-Control': 'no-store' } });

        const headers = new Headers();
        object.writeHttpMetadata(headers);
        headers.set('Content-Length', String(object.size));
        headers.set('ETag', object.httpEtag);
        headers.set('Cache-Control', name === 'appcast.xml' ? 'no-store' : 'public, max-age=31536000, immutable');
        headers.set('X-Content-Type-Options', 'nosniff');
        return new Response(request.method === 'HEAD' ? null : object.body, { headers });
    },
};
