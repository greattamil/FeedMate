// Reverse-proxy Worker for api.<domain> -> the Go API's Cloud Run origin.
//
// Why this exists: Cloud Run domain-mappings (the native "point my custom
// domain at this service" feature) aren't supported in every region —
// notably asia-south1, chosen for latency to India — so a Worker is used
// instead to terminate the custom domain at Cloudflare's edge and forward
// to Cloud Run's own *.run.app URL.
//
// ORIGIN_HOST is a wrangler.toml [vars] entry, not a hardcoded constant —
// migrating to a different Cloud Run region/project, or to an entirely
// different backend host, is a one-line edit in wrangler.toml, not a code
// change. EDGE_SHARED_SECRET is a Worker secret (set via
// `wrangler secret put EDGE_SHARED_SECRET`) that the origin's own
// middleware (services/api/internal/middleware.RequireEdgeSecret) requires
// on every request — this is what makes the origin's bare *.run.app URL
// reject direct traffic (internet-wide scanners, bots) that bypasses this
// Worker, since only this Worker knows the secret.
export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    url.hostname = env.ORIGIN_HOST;
    url.port = "443";
    url.protocol = "https:";

    const originRequest = new Request(url.toString(), request);
    originRequest.headers.set("Host", env.ORIGIN_HOST);
    originRequest.headers.set("X-Edge-Secret", env.EDGE_SHARED_SECRET);

    return fetch(originRequest);
  },
};
