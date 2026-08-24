//! pstream giga backend — Rust port of `index.js`.
//!
//! NOTE: the JS service this replaces is not deployed anywhere; see
//! PORTING.md. The full route surface of the
//! JS server is declared here from the start so that what is and isn't ported
//! is visible in one place: anything still on the JS side answers 501 with the
//! reason, rather than 404, which would be indistinguishable from a typo in a
//! caller's URL.
//!
//! See PORTING.md for scope and the two subsystems that need real work
//! (webtorrent, and shelling out to yt-dlp).

mod config;
mod routes;

use axum::{
    http::StatusCode,
    response::{IntoResponse, Response},
    routing::{delete, get, post},
    Json, Router,
};
use config::Config;
use routes::{passthrough, stateless};
use serde_json::json;
use std::sync::Arc;

#[derive(Clone)]
struct AppState {
    cfg: Arc<Config>,
}

/// Placeholder for a route still served by the JS backend.
///
/// 501 rather than 404 on purpose: a caller hitting this has found a real
/// route that simply isn't ported yet, and conflating that with "no such
/// route" wastes an afternoon when the frontend starts failing.
async fn not_ported(what: &'static str) -> Response {
    (
        StatusCode::NOT_IMPLEMENTED,
        Json(json!({
            "success": false,
            "error": "not_ported",
            "detail": format!("{what} is still served by the Node backend"),
        })),
    )
        .into_response()
}

async fn root() -> Response {
    Json(json!({ "ok": true, "service": "pstream-backend", "runtime": "rust" })).into_response()
}

async fn ping() -> Response {
    Json(json!({ "ok": true })).into_response()
}

#[tokio::main]
async fn main() {
    let cfg = Config::from_env();
    cfg.log_summary();
    let port = cfg.port;
    let state = AppState { cfg: Arc::new(cfg) };

    // Route names mirror index.js exactly. Grouped by subsystem, in the order
    // PORTING.md suggests tackling them.
    let app = Router::new()
        // ── live ─────────────────────────────────────────────────────────
        .route("/", get(root))
        .route("/api/ping", get(stateless::ping))
        .route("/healthcheck", get(stateless::healthcheck))
        .route("/api/stream", get(stateless::stream))
        .route("/api/youtube/search", get(stateless::youtube_search))
        .route("/api/subtitles/subdl", get(stateless::subdl_search))
        .route("/proxy/stream", get(pstream_shared::proxy::stream))
        .route("/proxy/m3u8", get(stateless::proxy_alias))
        .route("/proxy/video", get(stateless::proxy_alias))
        .route("/api/introdb/media", get(passthrough::media))
        .route("/proxy/subtitle", get(passthrough::subtitle))
        .route("/api/media-probe", get(pstream_shared::probe::media_probe))
        // ── still on Node ────────────────────────────────────────────────
        .route("/api/debug-providers", get(|| not_ported("/api/debug-providers")))
        .route("/api/providers/health", get(|| not_ported("/api/providers/health")))
        // waits on porting extractors/subs_vdrk.js, which it merges with IntroDB
        .route("/api/introdb/subtitles", get(|| not_ported("/api/introdb/subtitles")))
        .route("/proxy/subtitles/opensubtitles", get(|| not_ported("/proxy/subtitles/opensubtitles")))
        .route("/api/stream/diagnose", get(|| not_ported("/api/stream/diagnose")))
        .route("/api/stream/report-error", post(|| not_ported("/api/stream/report-error")))
        .route("/api/stream/report-success", post(|| not_ported("/api/stream/report-success")))
        // ── auth + sync ──────────────────────────────────────────────────
        .route("/api/auth/challenge", get(|| not_ported("/api/auth/challenge")))
        .route("/api/auth/verify", post(|| not_ported("/api/auth/verify")))
        .route("/api/sync", get(|| not_ported("GET /api/sync")))
        .route("/api/sync", post(|| not_ported("POST /api/sync")))
        .route("/api/sync", delete(|| not_ported("DELETE /api/sync")))
        .route(
            "/api/profiles/:profile_id/progress/:movie_id",
            get(|| not_ported("/api/profiles/:id/progress/:id")),
        )
        // ── trailers: shells out to yt-dlp ───────────────────────────────
        .route("/trailer/resolve", get(|| not_ported("/trailer/resolve")))
        .route("/trailer/cache", get(|| not_ported("/trailer/cache")))
        .route("/trailer/stream", get(|| not_ported("/trailer/stream")))
        .route("/trailer/cobalt", get(|| not_ported("/trailer/cobalt")))
        // ── torrents: needs librqbit, the largest piece ──────────────────
        .route("/api/torrent/sources", get(|| not_ported("/api/torrent/sources")))
        .route("/api/torrent/stream", get(|| not_ported("GET /api/torrent/stream")))
        .route("/api/torrent/stream", post(|| not_ported("POST /api/torrent/stream")))
        .route("/api/torrent/status", get(|| not_ported("/api/torrent/status")))
        .route("/api/hls/seg/:session_id/:file", get(|| not_ported("/api/hls/seg")))
        .route("/api/hls/session/:session_id", delete(|| not_ported("/api/hls/session")))
        // ── admin ────────────────────────────────────────────────────────
        .route("/admin", get(|| not_ported("/admin")))
        .with_state(state);

    let addr = format!("0.0.0.0:{port}");
    let listener = match tokio::net::TcpListener::bind(&addr).await {
        Ok(l) => l,
        Err(e) => {
            eprintln!("[backend] cannot bind {addr}: {e}");
            std::process::exit(1);
        }
    };

    println!("[backend] listening on http://0.0.0.0:{port}");
    if let Err(e) = axum::serve(listener, app).await {
        eprintln!("[backend] server error: {e}");
        std::process::exit(1);
    }
}
