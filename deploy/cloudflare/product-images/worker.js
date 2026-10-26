// Serves FeedMate product photos (R2) at images.<domain>.
//
// GET  /<key>  — public, no auth: anyone can view a product photo, same as
//                any other image on a storefront.
// PUT  /<key>  — bearer-token authenticated: only services/api's
//                UploadProductImage handler calls this, immediately after
//                validating and decoding the image it received from the
//                Flutter app. See wrangler.toml for the UPLOAD_SECRET note.
//
// Cache-Control is long-lived (30 days, immutable) because the key is
// deterministic per product (products/<tenant_id>/<product_id>.<ext>) and
// the API appends a ?v=<timestamp> query string to the URL it stores
// whenever a photo is replaced — that's what busts stale browser/edge
// caches on re-upload, not a short TTL.
export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const key = decodeURIComponent(url.pathname.replace(/^\/+/, ""));
    if (!key || key.includes("..")) {
      return new Response("Invalid key", { status: 400 });
    }

    if (request.method === "PUT") {
      const auth = request.headers.get("Authorization") || "";
      if (auth !== `Bearer ${env.UPLOAD_SECRET}`) {
        return new Response("Unauthorized", { status: 401 });
      }
      const contentType = request.headers.get("Content-Type") || "application/octet-stream";
      await env.IMAGES_BUCKET.put(key, request.body, { httpMetadata: { contentType } });
      return new Response(JSON.stringify({ stored: key }), {
        status: 200,
        headers: { "content-type": "application/json" },
      });
    }

    if (request.method === "OPTIONS") {
      return new Response(null, {
        status: 204,
        headers: {
          "access-control-allow-origin": "*",
          "access-control-allow-methods": "GET, HEAD, OPTIONS",
          "access-control-max-age": "86400",
        },
      });
    }

    if (request.method === "GET" || request.method === "HEAD") {
      const object = await env.IMAGES_BUCKET.get(key);
      if (object === null) {
        return new Response("Not found", { status: 404 });
      }
      const headers = new Headers();
      object.writeHttpMetadata(headers);
      headers.set("etag", object.httpEtag);
      headers.set("cache-control", "public, max-age=2592000, immutable");
      headers.set("access-control-allow-origin", "*");
      return new Response(request.method === "HEAD" ? null : object.body, { headers });
    }

    return new Response("Method not allowed", { status: 405 });
  },
};
