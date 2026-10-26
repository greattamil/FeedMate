# BPKS Cattle Feed – Website

Static site + one small Cloudflare worker (`_worker.js`). Runs on the Cloudflare **free** plan (100,000 requests/day), no card needed.

## Files
- `index.html` – the website (Tamil + English)
- `img/` – photos and logo
- `_worker.js` – serves the site and handles the order form at `/api/order`

## Deploy (drag & drop)
1. dash.cloudflare.com → **Workers & Pages → Create → Pages → Upload assets**
2. Project name: `bpks-cattle-feed` → site will be `https://bpks-cattle-feed.pages.dev`
3. Drag this whole folder in → **Deploy**

## How orders reach the shop
1. **WhatsApp (always works, no setup):** after the customer fills the form, WhatsApp opens with the full order typed out, addressed to 9159325662. The customer taps Send.
2. **Instant alert (optional, free):** the worker also sends the order to the owner automatically, even if the customer never taps Send. Set either option below in
   **Project → Settings → Variables and Secrets**, then redeploy.

### Option A – Telegram alert (recommended, official and free)
1. In Telegram, open **@BotFather** → `/newbot` → copy the bot token.
2. Open your new bot and send it "hi".
3. Open `https://api.telegram.org/bot<TOKEN>/getUpdates` in a browser and copy `"chat":{"id": ...}`.
4. Add `TELEGRAM_BOT_TOKEN` and `TELEGRAM_CHAT_ID` as secrets.

### Option B – WhatsApp alert via CallMeBot (free, third-party)
1. Go to callmebot.com → WhatsApp API and save the CallMeBot phone number shown there in the owner's contacts.
2. From the owner's WhatsApp send: `I allow callmebot to send me messages`
3. You'll receive an API key. Add `CALLMEBOT_PHONE` = `919159325662` and `CALLMEBOT_APIKEY` = the key.

CallMeBot is a free personal-use service, not an official WhatsApp product, so treat it as a convenience. Fully official automatic WhatsApp messages need the WhatsApp Business Platform, which charges per message.

## Site settings (social links, hours, prices, delivery, payment)
**The site currently shows SAMPLE data** (prices, hours, social links, delivery area, payment methods, GST/licence numbers).
A yellow "sample details" strip at the top reminds you. Replace everything, then set `demo:false`.
While `demo:true`, the business details for Google are switched off so sample hours/prices are never indexed.

Open `bpks-website/index.html`, search for `SITE SETTINGS` and fill in:
- `social` – full links to Facebook / Instagram / YouTube / WhatsApp Channel. Empty ones stay hidden.
- `hours` – shop timings in Tamil and English. Hidden until filled.
- `prices` – ₹ per 50 kg bag (0 hides the price), plus `priceDate`.
- `delivery`, `payment`, `certs` – Tamil + English text. Empty hides them.
- `hoursSchema` – the same hours in Google's format, e.g. `Mo-Sa 08:00-20:00`.
- `mapsUrl` – in Google Maps, open the shop pin → Share → Copy link, and paste it here.
- `site` – change only if your Cloudflare address or own domain is different from `https://bpks-cattle-feed.pages.dev`.

If the address is different, also replace `bpks-cattle-feed.pages.dev` in `index.html` (share-preview tags at the top), `robots.txt` and `sitemap.xml`.

## After going live
1. Create a free **Google Business Profile** for the shop and add the website link.
2. Add the site in **Google Search Console** and submit `/sitemap.xml`.
3. Test the WhatsApp share preview by sending the site link to yourself.
