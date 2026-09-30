# MixBot API — deployed state

Cloudflare Worker serving the MixBot drink menu. **Already deployed and live** —
nothing here needs to be recreated. `SETUP.md` records the original one-time
setup; this file records what exists now.

## Live deployment

| Thing | Value |
|-------|-------|
| Live URL | `https://mixbot-api.kixlobo.workers.dev` |
| Worker name | `mixbot-api` (Cloudflare account subdomain: `kixlobo`) |
| KV namespace | title `mixbot-api-MENU_KV`, id `a4f9dfac66e041b7b88ac1818d01d94d`, binding `MENU_KV` |
| KV keys | `menu` (current), `menu-backup` (previous version) |
| Secret | `MENU_TOKEN` = `Q1V9H/0fvtF/X4jsRGxK4QeJzwpBgjqq` (set via `wrangler secret put`; also baked into the app for saves) |
| First deployed | 2026-09-30 |

Naming convention: every MixBot resource in the Cloudflare account uses the
`mixbot-` prefix so entries cluster together. Future backend features are
added as **routes on this same worker** (not new workers); future storage
(e.g. a D1 database for pour history) also gets the `mixbot-` prefix.

## Endpoints

| Route | Auth | Behavior |
|-------|------|----------|
| `GET /menu` | none | Current menu JSON. Headers: `ETag` / `X-Updated-At` (the version token), `Cache-Control: no-store` |
| `PUT /menu` | `Authorization: Bearer <MENU_TOKEN>` | Validates (422 + list of every problem on failure), requires `If-Match: <updatedAt>` of the version the edit started from (409 if stale), backs up the current version, stores the new one |
| `GET /menu/backup` | Bearer token | Previous menu version. To roll back: save its output, re-PUT it |

Update flow: `GET /menu` → note `X-Updated-At` → edit → `PUT /menu` with
`If-Match`. The first-ever PUT into an empty store needs no `If-Match`.

Example update:

```sh
curl -X PUT "https://mixbot-api.kixlobo.workers.dev/menu" \
  -H "Authorization: Bearer Q1V9H/0fvtF/X4jsRGxK4QeJzwpBgjqq" \
  -H "If-Match: <value of X-Updated-At from GET>" \
  -H "Content-Type: application/json" \
  --data-binary @menu.json
```

## Redeploying after code changes

From this folder (requires `npx wrangler login` once per machine):

```sh
npx wrangler deploy
```

`wrangler.toml` already contains the real KV namespace id. Secrets survive
deploys; only re-run `wrangler secret put MENU_TOKEN` if rotating the token.

## Validation rules (mirrored in the app's DrinkMenu.swift)

- `version == 2`; `stations` non-empty, integer ids, unique, non-empty names
- `drinks` non-empty; drink names non-empty and unique (they are the app's
  stable identity); `totalQty` positive integer; `description` a string
- Ingredients: `stationId` must exist in `stations`, `percent` in 0…100,
  per-drink percents sum to 100 (±0.5), optional `label` overrides the
  station name for display only — the robot pours from the station
- A rejected PUT never modifies stored data

## Related pieces

- App loader: `MixBot/MenuManager.swift` (points at the live URL; falls back
  to cached copy, then bundled `MixBot/Resources/drinks.json`)
- Wire format model + same validation in-app: `MixBot/MixBot/Models/DrinkMenu.swift`
- Robot BLE payload (`D:stationId=amount,...` in `RemoteEngine.swift`) is
  independent of all of this and unchanged
- Legacy: `https://www.grupomovic.com/mixtender/drinks.json` (v1 array format)
  still serves pre-v2 app builds; `drinks_v2.json` on grupomovic.com is no
  longer used by current builds
- `../drinks_v2.json` is the seed copy of the menu that was first uploaded
