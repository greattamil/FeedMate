// Serves the FeedMate downloads bucket (R2) at downloads.<domain>.
//
// Why this exists: a plain R2 custom domain serves raw objects only — it
// has no concept of "/" meaning index.html, the way a normal web host
// does, so the landing page (deploy/cloudflare/downloads-landing/index.html)
// was unreachable at the bare domain. This Worker is the standard fix:
// bind the bucket, resolve "/" (and any path ending in "/") to
// "index.html", and stream everything else straight from R2 with its
// real content-type and length preserved.
export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    let key = decodeURIComponent(url.pathname.replace(/^\/+/, ""));
    if (key === "" || key.endsWith("/")) key += "index.html";

    const object = await env.DOWNLOADS_BUCKET.get(key);
    if (object === null) {
      return new Response("Not found", { status: 404 });
    }

    const headers = new Headers();
    object.writeHttpMetadata(headers);
    headers.set("etag", object.httpEtag);
    if (!headers.has("content-type")) {
      headers.set("content-type", guessContentType(key));
    }
    headers.set("cache-control", key === "index.html" || key === "version.json" ? "no-cache" : "public, max-age=3600");

    return new Response(object.body, { headers });
  },
};

function guessContentType(key) {
  if (key.endsWith(".html")) return "text/html; charset=utf-8";
  if (key.endsWith(".json")) return "application/json";
  if (key.endsWith(".apk")) return "application/vnd.android.package-archive";
  if (key.endsWith(".zip")) return "application/zip";
  return "application/octet-stream";
}
