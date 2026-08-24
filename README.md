# pstream-backend-rs

Rust port of the pstream giga backend.

> **Before adding anything here, read [PORTING.md](PORTING.md).**
> The JS service this replaces is **not deployed anywhere**. The frontend
> points at the phone resolver, and calls Supabase directly from the browser.
> Most of the 37 routes have no caller, so the question for each is whether it
> should exist at all — not which crate replaces `ioredis`.

## What's live

Eleven routes, wired to
[`pstream-shared`](https://github.com/Coderia397/pstream-resolver-rs) rather
than reimplemented — the same code the phone runs, so a provider fix lands in
both services at once.

```
/  /api/ping  /healthcheck  /api/stream  /api/youtube/search
/api/subtitles/subdl  /proxy/stream  /proxy/m3u8  /proxy/video
/api/introdb/media  /proxy/subtitle  /api/media-probe
```

The remaining routes answer **501 with the reason**, not 404. A caller hitting
one has found a real endpoint that isn't ported yet, and conflating that with
"no such route" turns a five-minute fix into an afternoon.

## Configuration

Every value is optional, matching the JS. A missing variable disables one
subsystem rather than stopping the server, and each is logged at boot so a
misconfigured deployment is obvious immediately rather than at first request.

| variable | effect if unset |
|---|---|
| `PORT` | 7860 |
| `REDIS_URL` | provider health is not persisted; all providers assumed healthy |
| `SUPABASE_URL` / `SUPABASE_SERVICE_KEY` | profile and sync routes unavailable |
| `JWT_SECRET` | session tokens cannot be issued |
| `SUBDL_API_KEY` | subtitle search reports itself unconfigured |
| `ALLDEBRID_API_KEY` | debrid unavailable |
| `RESIDENTIAL_PROXY_URL` | providers reached directly |
| `ADMIN_TOKEN` | the admin page is refused outright |

## Running

```sh
cargo run
cargo test
```

## License

MIT — see [LICENSE](LICENSE).
