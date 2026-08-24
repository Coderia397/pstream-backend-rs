# Porting the giga backend to Rust

Scope, and an honest account of what does and doesn't translate. Written
while surveying `pstream-backend` at commit `0dabc03`.

## What this covers

`index.js` (2,079 lines, **37 routes**), `resolver.js` (342), `services/`
(1,184), `utils/` (457), `worker/` (194) — roughly **4,250 lines**.

This runs on a **Hugging Face Space**, not the phone. So the argument that
justified the resolver port (a 3.4 MB static binary with no node runtime on a
battery-powered device) does **not** apply here. Node is fine on a Space. The
reasons that do still hold:

- no dependency resolution at deploy time
- the compiler enforcing payload shapes across 37 routes
- one toolchain across both services

If you want a reason to stop, that's the honest one: this port buys less than
the resolver port did.

## Straightforward

| JS | Rust | Notes |
|---|---|---|
| express | axum | already proven in the resolver |
| cors | tower-http `CorsLayer` | keep the allowlist, not `*` |
| axios | reqwest | shared client module carries over |
| ioredis | `redis` | provider health, caches |
| jsonwebtoken | `jsonwebtoken` | same claims |
| tweetnacl | `ed25519-dalek` | `utils/challenge.js` sign/verify |
| dotenv | `dotenvy` | |
| @supabase/supabase-js | `reqwest` against PostgREST | the JS client is a thin HTTP wrapper; no crate needed |
| http-proxy-middleware | hand-rolled, as `proxy.rs` already is | |

Directly reusable from `pstream-resolver-rs`: `http.rs`, `models.rs`,
`cache.rs`, `proxy.rs`, `cors.rs`, `ratelimit.rs`, and all 13 extractors.
Worth extracting into a shared workspace crate rather than copying.

## The two that don't translate

### 1. `webtorrent` — `services/torrent.js`, 657 lines

A full BitTorrent client with range-served streaming and a live
`activeMap` of torrents. There is no drop-in equivalent.

The real option is **`librqbit`** — a mature Rust BitTorrent client that
supports streaming reads, so `streamTorrent` is expressible. But it is a
different API, not a translation, and this is the single largest piece of
work in the port. Budget it separately from everything else.

### 2. `yt-dlp-exec` — `services/trailer.js`

Only a wrapper that shells out to the `yt-dlp` binary. In Rust, invoke the
same binary with `tokio::process::Command` — arguably cleaner, since the
wrapper is what broke `npm install` on the phone (its postinstall runs a
python version check that fails in Termux).

`spawn` in `index.js` is the same story: it drives ffmpeg for the HLS
session endpoints, and shells out identically from Rust.

## Suggested order

1. **Foundation** — config, shared http, Redis, Supabase REST, JWT + ed25519
   challenge. Unblocks everything else.
2. **Stateless routes** — ping, healthcheck, debug-providers, provider health,
   introdb, youtube, subdl, the proxy family. Mostly already written for the
   resolver.
3. **Resolver core** — `resolveStreaming` / `diagnoseProviders`, reusing the
   13 ported extractors.
4. **Auth + sync** — challenge/verify, and the GET/POST/DELETE sync trio
   against Supabase.
5. **Trailers** — shelling out to yt-dlp, plus the cache endpoints.
6. **Torrents** — librqbit. Last, and largest.

## Not carried over

The 7 dependencies removed in `0dabc03` are not reinstated: nothing imported
them. Notably the puppeteer trio was declared but unused, and its install hook
pulls Chromium.
