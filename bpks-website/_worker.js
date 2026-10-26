// BPKS Cattle Feed – Cloudflare Pages worker (free plan).
// Serves the static site and handles POST /api/order:
// sends an instant alert to the shop owner on Telegram and/or WhatsApp (CallMeBot).
//
// Set these in Cloudflare → Workers & Pages → your project → Settings → Variables and Secrets:
//   TELEGRAM_BOT_TOKEN   (from @BotFather)          – optional
//   TELEGRAM_CHAT_ID     (owner's chat id)          – optional
//   CALLMEBOT_PHONE      e.g. 919159325662          – optional
//   CALLMEBOT_APIKEY     (from CallMeBot activation) – optional
// If none are set, the site still works: orders reach the shop through the customer's WhatsApp message.

const json = (data, status = 200) =>
  new Response(JSON.stringify(data), {
    status,
    headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" },
  });

const clip = (v, n) => String(v ?? "").replace(/[\u0000-\u001f\u007f]/g, " ").trim().slice(0, n);

function buildMessage(o) {
  const totalBags = o.items.reduce((s, i) => s + i.bags, 0);
  const totalKg = o.items.reduce((s, i) => s + (i.bags * (i.packSize || 50)), 0);
  const lines = [
    "🛒 BPKS புதிய ஆர்டர் (இணையதளம்)",
    "",
    `பெயர்: ${o.name}`,
    `மொபைல்: ${o.phone}`,
    "",
    ...o.items.map((i) => `• ${i.feed}${i.packSize ? ' (' + i.packSize + ' kg)' : ''} × ${i.bags} மூட்டை` + (i.subtotal ? ` = ₹${Number(i.subtotal).toLocaleString('en-IN')}` : (i.price ? ` (@ ₹${i.price})` : ""))),
    `மொத்தம்: ${totalBags} மூட்டை (${totalKg} kg)`,
  ];
  if (o.estimatedTotal) {
    lines.push(`தோராய தொகை: ₹${Number(o.estimatedTotal).toLocaleString('en-IN')}`);
  }
  lines.push(
    "",
    `முறை: ${o.mode === "delivery" ? "இலவச டோர் டெலிவரி" : "கடையில் பெறுதல்"}`
  );
  if (o.mode === "delivery") lines.push(`முகவரி: ${o.address}`);
  lines.push(`எப்போது: ${o.when}`);
  if (o.note) lines.push(`குறிப்பு: ${o.note}`);
  lines.push("", `அழைக்க: tel:+91${o.phone}`, `WhatsApp: https://wa.me/91${o.phone}`);
  return lines.join("\n");
}

async function handleOrder(request, env) {
  let body;
  try {
    body = await request.json();
  } catch {
    return json({ ok: false, error: "bad_json" }, 400);
  }
  if (body.website) return json({ ok: true }); // honeypot: silently drop bots

  const items = (Array.isArray(body.items) ? body.items : [])
    .map((i) => ({
      feed: clip(i.feed, 80),
      bags: Math.min(200, Math.max(0, parseInt(i.bags, 10) || 0)),
      packSize: Math.max(1, parseInt(i.packSize, 10) || 50),
      price: parseInt(i.price, 10) || 0,
      subtotal: parseInt(i.subtotal, 10) || 0,
    }))
    .filter((i) => i.feed.length > 0 && i.bags > 0);

  const order = {
    name: clip(body.name, 60),
    phone: clip(body.phone, 10).replace(/\D/g, ""),
    mode: body.mode === "pickup" ? "pickup" : "delivery",
    address: clip(body.address, 200),
    when: clip(body.when, 20),
    note: clip(body.note, 120),
    estimatedTotal: parseInt(body.estimatedTotal, 10) || 0,
    items,
  };

  if (order.name.length < 2 || !/^[6-9]\d{9}$/.test(order.phone) || !items.length ||
      (order.mode === "delivery" && order.address.length < 4)) {
    return json({ ok: false, error: "invalid" }, 422);
  }

  const text = buildMessage(order);
  const jobs = [];

  if (env.TELEGRAM_BOT_TOKEN && env.TELEGRAM_CHAT_ID) {
    jobs.push(
      fetch(`https://api.telegram.org/bot${env.TELEGRAM_BOT_TOKEN}/sendMessage`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ chat_id: env.TELEGRAM_CHAT_ID, text, disable_web_page_preview: true }),
      }).then((r) => r.ok)
    );
  }
  if (env.CALLMEBOT_PHONE && env.CALLMEBOT_APIKEY) {
    const u = new URL("https://api.callmebot.com/whatsapp.php");
    u.searchParams.set("phone", env.CALLMEBOT_PHONE);
    u.searchParams.set("text", text);
    u.searchParams.set("apikey", env.CALLMEBOT_APIKEY);
    jobs.push(fetch(u.toString()).then((r) => r.ok));
  }

  if (!jobs.length) return json({ ok: false, error: "not_configured" }, 503);
  const results = await Promise.allSettled(jobs);
  const sent = results.filter((r) => r.status === "fulfilled" && r.value).length;
  return json({ ok: sent > 0, sent }, sent > 0 ? 200 : 502);
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname === "/api/order") {
      if (request.method !== "POST") return json({ ok: false, error: "method" }, 405);
      return handleOrder(request, env);
    }
    const res = await env.ASSETS.fetch(request);
    const out = new Response(res.body, res);
    out.headers.set("X-Content-Type-Options", "nosniff");
    out.headers.set("Referrer-Policy", "strict-origin-when-cross-origin");
    out.headers.set("X-Frame-Options", "SAMEORIGIN");
    out.headers.set("Permissions-Policy", "camera=(), microphone=(), geolocation=()");
    if (url.pathname.startsWith("/img/")) out.headers.set("Cache-Control", "public, max-age=2592000");
    return out;
  },
};
