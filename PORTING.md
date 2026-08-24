# Porting the giga backend to Rust

Scope, and an honest account of what does and doesn't translate.

## Read this first: the thing being ported is not deployed

`index.js` — 2,079 lines, 37 routes — **is not running anywhere.**

`DEPLOY.md` in the JS repo says the backend is "designed for Hugging Face
Spaces", and this document originally read that as *deployed there*. It isn't.
Checking what the frontend actually talks to:

```
pstream-frontend/.env
  VITE_GIGA_BACKEND_URL=https://resolver.pstream.watch     ← the phone
  VITE_SUPABASE_URL=https://…supabase.co                   ← called from the browser
```

That is the only backend URL in the frontend. No `hf.space`, no Render, no
Fly, no Workers anywhere in the source. Supabase is called **directly from the
browser**, so the backend's auth and sync routes have no consumer either.

And the frontend calls exactly four endpoints: `/api/stream`, `/proxy/stream`,
`/api/media-probe`, and `/tmdb`. All four are the phone's business, and the
first three are already served there in Rust. `/tmdb` is unreachable and
unused — `services/tmdb.ts` only falls back to it when `VITE_TMDB_API_KEY` is
unset, and it is set.

**So most of the 37 routes have no caller.** Before porting any of them, the
question is whether they should exist at all rather than which crate replaces
`ioredis`.

## What still holds

Routes worth having, if this service ever gets deployed:

- the resolver core, already done in `pstream-shared`
- the proxy family, already done
- provider health, if you want reliability scores to survive a restart

Everything else — torrents, AllDebrid, trailers, the admin page, auth, sync —
is unreferenced by the frontend as it stands.

## Straightforward, if it goes ahead

| JS | Rust | Notes |
|---|---|---|
| express | axum | proven in the resolver |
| cors | `pstream_shared::cors` | keep the allowlist, not `*` |
| axios | `pstream_shared::http` | already shared |
| ioredis | `redis` | optional by design — see below |
| jsonwebtoken | `jsonwebtoken` | |
| tweetnacl | `ed25519-dalek` | `utils/challenge.js` |
| @supabase/supabase-js | `reqwest` against PostgREST | the JS client is a thin HTTP wrapper |

Redis deserves a note: `utils/redis.js` returns a **no-op client** when
`REDIS_URL` is unset, and every call site swallows failure. Without it every
provider is simply assumed healthy. It is a nice-to-have, not a dependency.

## The two that don't translate

**`webtorrent`** — `services/torrent.js`, 657 lines. A full BitTorrent client
with range-served streaming and a live map of active torrents. `librqbit` can
do it, but that is a rewrite rather than a translation, and it is the largest
single piece of work here by a wide margin. It also has no caller today.

**`yt-dlp-exec`** — `services/trailer.js`. Only a wrapper that shells out to
the `yt-dlp` binary; Rust invokes the same binary with
`tokio::process::Command`. Arguably cleaner: that wrapper's postinstall runs a
python version check that fails in Termux, which is what broke `npm install`
on the phone.

## Already carried over

Nine routes are live here, wired to `pstream-shared` rather than
reimplemented: `/api/stream`, `/api/youtube/search`, `/api/subtitles/subdl`,
`/proxy/stream`, the two proxy aliases, `/api/introdb/media`,
`/proxy/subtitle`, plus ping/healthcheck.

Unported routes answer **501 with the reason**, not 404, so "not ported" stays
distinguishable from "wrong URL".
