//! Routes that need nothing but the shared crate — no Redis, no Supabase, no
//! torrent engine. These are the ones the phone resolver already implements,
//! so here they are thin wiring rather than new code.

use axum::{
    extract::Query,
    http::{HeaderMap, HeaderName, HeaderValue, StatusCode, Uri},
    response::{IntoResponse, Redirect, Response},
    Json,
};
use pstream_shared::{cache, cors, extractors, ratelimit, subdl, youtube, MediaKind, ProviderResult};
use serde::Deserialize;
use serde_json::json;
use std::time::Duration;

/// Resolved URLs outlive this comfortably (VixSrc playlist tokens run ~60
/// days), so 6h is well short of expiry while letting a title that breaks
/// upstream self-heal within the day.
const CACHE_TTL: Duration = Duration::from_secs(6 * 60 * 60);

fn ok(req: &HeaderMap, v: serde_json::Value) -> Response {
    (StatusCode::OK, cors::headers_for(req), Json(v)).into_response()
}

fn fail(req: &HeaderMap, code: StatusCode, v: serde_json::Value) -> Response {
    (code, cors::headers_for(req), Json(v)).into_response()
}

/// Digits only, bounded length. These values are interpolated into provider
/// URL paths and into cache keys, so an unchecked one could reshape a request
/// or flood the cache with junk that evicts real entries.
fn numeric_within(s: &str, max_digits: usize) -> bool {
    !s.is_empty() && s.len() <= max_digits && s.bytes().all(|b| b.is_ascii_digit())
}

// ── /api/ping and /healthcheck ───────────────────────────────────────────────

pub async fn ping(headers: HeaderMap) -> Response {
    ok(&headers, json!({ "ok": true }))
}

pub async fn healthcheck(headers: HeaderMap) -> Response {
    ok(
        &headers,
        json!({
            "ok": true,
            "service": "pstream-backend",
            "runtime": "rust",
            "providers": extractors::PROVIDERS.len() + 4, // table + vixsrc, lookmovie, moviebox, nontongo
        }),
    )
}

// ── /api/stream ──────────────────────────────────────────────────────────────

#[derive(Debug, Deserialize)]
pub struct StreamQuery {
    #[serde(alias = "id", alias = "tmdbId")]
    tmdb_id: Option<String>,
    #[serde(alias = "type")]
    kind: Option<String>,
    season: Option<u32>,
    episode: Option<u32>,
    title: Option<String>,
    year: Option<u32>,
}

pub async fn stream(headers: HeaderMap, Query(q): Query<StreamQuery>) -> Response {
    let tmdb_id = q.tmdb_id.unwrap_or_default();
    if !numeric_within(&tmdb_id, 12) {
        return fail(
            &headers,
            StatusCode::BAD_REQUEST,
            json!({ "success": false, "error": "tmdbId must be numeric" }),
        );
    }

    let season = q.season.unwrap_or(1);
    let episode = q.episode.unwrap_or(1);
    if season > 9_999 || episode > 99_999 {
        return fail(
            &headers,
            StatusCode::BAD_REQUEST,
            json!({ "success": false, "error": "season/episode must be numeric" }),
        );
    }

    let type_label = if q.kind.as_deref() == Some("tv") { "tv" } else { "movie" };
    let kind = MediaKind::parse(type_label);
    let title: Option<String> = q
        .title
        .map(|t| t.chars().take(200).collect::<String>())
        .filter(|t| !t.is_empty());

    // A cache hit costs nothing and touches no provider, so it is served
    // before the rate limiter rather than after.
    let key = format!("{type_label}:{tmdb_id}:{season}:{episode}");
    if let Some(hit) = cache::get(&key) {
        return (
            StatusCode::OK,
            cors::headers_for(&headers),
            [(HeaderName::from_static("x-cache"), HeaderValue::from_static("HIT"))],
            Json(hit),
        )
            .into_response();
    }

    let ip = ratelimit::client_ip(&headers);
    if ratelimit::check(&ip) {
        return (
            StatusCode::TOO_MANY_REQUESTS,
            cors::headers_for(&headers),
            [(HeaderName::from_static("retry-after"), HeaderValue::from_static("60"))],
            Json(json!({ "success": false, "error": "Too many requests — please slow down." })),
        )
            .into_response();
    }

    let working: Vec<ProviderResult> =
        extractors::run_all(&tmdb_id, kind, season, episode, title.as_deref(), q.year).await;

    let Some(winner) = working.first() else {
        return fail(
            &headers,
            StatusCode::NOT_FOUND,
            json!({
                "success": false,
                "error": "No stream found. All providers are currently unavailable."
            }),
        );
    };

    let payload = json!({
        "success": true,
        "provider": winner.provider,
        "providerId": winner.provider_id,
        "sources": working.iter().flat_map(|r| r.sources.iter()).collect::<Vec<_>>(),
        "subtitles": working.iter().flat_map(|r| r.subtitles.iter()).collect::<Vec<_>>(),
    });

    cache::put(key, payload.clone(), CACHE_TTL);
    ok(&headers, payload)
}

// ── /api/youtube/search ──────────────────────────────────────────────────────

#[derive(Debug, Deserialize)]
pub struct YoutubeQuery {
    #[serde(alias = "query")]
    q: Option<String>,
    #[serde(alias = "maxResults")]
    max_results: Option<usize>,
}

pub async fn youtube_search(headers: HeaderMap, Query(p): Query<YoutubeQuery>) -> Response {
    let query = p.q.unwrap_or_default();
    if query.is_empty() {
        return fail(
            &headers,
            StatusCode::BAD_REQUEST,
            json!({ "results": [], "error": "q parameter required" }),
        );
    }
    let max = p.max_results.unwrap_or(5).clamp(1, 20);
    let results = youtube::search(&query.chars().take(200).collect::<String>(), max).await;
    ok(&headers, json!({ "results": results }))
}

// ── /api/subtitles/subdl ─────────────────────────────────────────────────────

#[derive(Debug, Deserialize)]
pub struct SubdlQuery {
    #[serde(alias = "id", alias = "tmdbId")]
    tmdb_id: Option<String>,
    #[serde(alias = "type")]
    kind: Option<String>,
    season: Option<u32>,
    episode: Option<u32>,
    #[serde(alias = "language")]
    langs: Option<String>,
}

pub async fn subdl_search(headers: HeaderMap, Query(p): Query<SubdlQuery>) -> Response {
    let tmdb_id = p.tmdb_id.unwrap_or_default();
    if !numeric_within(&tmdb_id, 12) {
        return fail(
            &headers,
            StatusCode::BAD_REQUEST,
            json!({ "subtitles": [], "error": "tmdbId must be numeric" }),
        );
    }

    let body = subdl::search(subdl::SearchArgs {
        tmdb_id: &tmdb_id,
        is_tv: p.kind.as_deref() == Some("tv"),
        season: p.season.unwrap_or(1).min(9_999),
        episode: p.episode.unwrap_or(1).min(99_999),
        langs: &p.langs.unwrap_or_else(|| "EN".to_string()),
    })
    .await;

    ok(&headers, body)
}

// ── /proxy/m3u8 and /proxy/video ─────────────────────────────────────────────

/// Both are historical aliases the frontend may still hold in cached bundles.
/// index.js answers them with a permanent redirect carrying the query string
/// through, and so do we.
pub async fn proxy_alias(uri: Uri) -> Response {
    let qs = uri.query().unwrap_or_default();
    Redirect::permanent(&format!("/proxy/stream?{qs}")).into_response()
}
