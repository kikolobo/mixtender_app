# MixBot API (mixbot-api) — one-time setup

Run these from this folder:

```sh
cd "/Users/frlobo/Documents/Development/Source Code/XCode/MixBot/MixBot/mixbot-api"
```

## 1. Log in to Cloudflare (opens a browser)

```sh
npx wrangler login
```

## 2. Create the KV namespace

```sh
npx wrangler kv namespace create MENU_KV
```

This prints an `id = "..."` line. Paste that id into `wrangler.toml`,
replacing `PASTE_KV_NAMESPACE_ID_HERE` (or tell Claude the id and it will
update the file).

## 3. Deploy the worker

```sh
npx wrangler deploy
```

This prints the live URL, e.g. `https://mixbot-api.<your-account>.workers.dev`.

## 4. Set the API secret

```sh
npx wrangler secret put MENU_TOKEN
```

When prompted, paste the shared secret:

```
Q1V9H/0fvtF/X4jsRGxK4QeJzwpBgjqq
```

(Or use your own — just use the same value in the app later.)

## 5. Seed the menu (first upload)

Uses the corrected `drinks_v2.json` in the folder above. Replace
`<your-account>` with the subdomain from step 3:

```sh
curl -X PUT "https://mixbot-api.<your-account>.workers.dev/menu" \
  -H "Authorization: Bearer Q1V9H/0fvtF/X4jsRGxK4QeJzwpBgjqq" \
  -H "Content-Type: application/json" \
  --data-binary @../drinks_v2.json
```

Expected: `{ "ok": true, "updatedAt": "..." }`

## 6. Verify

```sh
curl "https://mixbot-api.<your-account>.workers.dev/menu"
```

Should return the menu JSON, with `X-Updated-At` and `ETag` headers.

## Day-to-day

- Read menu: `GET /menu` (public)
- Update menu: `PUT /menu` with the Bearer token AND an `If-Match: <updatedAt>`
  header naming the version you started from (from GET's `X-Updated-At`).
  A stale `If-Match` returns 409 — refresh and retry.
- Bad files are rejected with 422 and a list of every problem found.
- Previous version: `GET /menu/backup` (Bearer token). To roll back,
  save its output and re-PUT it.
