// Two jobs in one small Worker:
//
// 1. scheduled() — fires daily (see wrangler.toml's cron trigger) and
//    calls the API's own /internal/cron/trigger-db-backup, which in turn
//    (via internal/domain/dbbackup on the Go side) starts the
//    feedmate-db-backup Cloud Run Job. Replaces what used to be a Google
//    Cloud Scheduler job — moving scheduling to Cloudflare's own Cron
//    Triggers (free, no per-account job-count limit like GCP Scheduler
//    has) while the actual pg_dump keeps running on Cloud Run, since
//    Workers can't execute arbitrary binaries.
//
// 2. fetch() — a small authenticated upload receiver the Cloud Run Job's
//    backup.sh PUTs the finished dump to, bound directly to the
//    bpks-db-backups R2 bucket (a native binding, not S3-style
//    access-key credentials — nothing for anyone to leak). No GCS
//    anywhere in this path.
export default {
  async scheduled(event, env, ctx) {
    const resp = await fetch("https://api.bpkscattlefeeds.com/api/v1/internal/cron/trigger-db-backup", {
      method: "POST",
      headers: { "X-Cron-Secret": env.CRON_SECRET },
    });
    if (!resp.ok) {
      console.error(`trigger-db-backup failed: ${resp.status} ${await resp.text()}`);
    }
  },

  async fetch(request, env) {
    if (request.method !== "PUT") {
      return new Response("Method not allowed", { status: 405 });
    }
    const auth = request.headers.get("Authorization") || "";
    if (auth !== `Bearer ${env.UPLOAD_SECRET}`) {
      return new Response("Unauthorized", { status: 401 });
    }
    const key = decodeURIComponent(new URL(request.url).pathname.replace(/^\/+/, ""));
    if (!key || key.includes("..")) {
      return new Response("Invalid key", { status: 400 });
    }
    await env.BACKUP_BUCKET.put(key, request.body);
    return new Response(JSON.stringify({ stored: key }), {
      status: 200,
      headers: { "content-type": "application/json" },
    });
  },
};
