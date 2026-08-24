//! Routes that only fetch something upstream and hand it back.
//!
//! They exist because a browser can't make these requests itself — either the
//! upstream sends no CORS headers, or the request needs an Origin the browser
//! won't forge. Nothing here needs Redis, Supabase or any credential.

use axum::{
    extract::Query,
    http::{header, HeaderMap, StatusCode},
    response::{IntoResponse, Response},
    Json,
};
use pstream_shared::{
    cors,
    http::{get_text_with, GIGA},
};
use serde::Deserialize;
use serde_json::{json, Value};
use std::time::Duration;

const INTRODB: &str = "https://api.theintrodb.org";
const PSTREAM_ORIGIN: &str = "https://pstream.watch";

/// IntroDB rejects requests that don't look like they came from the site.
fn introdb_headers() -> Vec<(&'static str, &'static str)> {
    vec![
        ("Origin", PSTREAM_ORIGIN),
        ("Referer", "https://pstream.watch/"),
        ("Accept", "application/json"),
    ]
}

fn numeric_within(s: &str, max_digits: usize) -> bool {
    !s.is_empty() && s.len() <= max_digits && s.bytes().all(|b| b.is_ascii_digit())
}

// ── /api/introdb/media ───────────────────────────────────────────────────────

#[derive(Debug, Deserialize)]
pub struct IntroQuery {
    tmdb_id: Option<String>,
    #[serde(alias = "type")]
    kind: Option<String>,
    season: Option<u32>,
    episode: Option<u32>,
}

/// Intro/outro segment timings for the skip button.
///
/// Failure returns an empty segment list rather than an error status, matching
/// the JS: the player treats "no segments" as "nothing to skip", whereas a 500
/// makes it look like playback itself is broken.
pub async fn media(headers: HeaderMap, Query(q): Query<IntroQuery>) -> Response {
    let empty = || (StatusCode::OK, cors::headers_for(&headers), Json(json!({ "segments": [] }))).into_response();

    let Some(id) = q.tmdb_id.filter(|s| numeric_within(s, 12)) else {
        return empty();
    };

    let mut url = format!("{INTRODB}/v2/media?tmdb_id={id}");
    if let Some(s) = q.season {
        url.push_str(&format!("&season={s}"));
    }
    if let Some(e) = q.episode {
        url.push_str(&format!("&episode={e}"));
    }

    match get_text_with(&GIGA, &url, Duration::from_secs(8), &introdb_headers()).await {
        Some(body) => match serde_json::from_str::<Value>(&body) {
            Ok(v) => (StatusCode::OK, cors::headers_for(&headers), Json(v)).into_response(),
            Err(_) => {
                println!("[IntroDB Media] response was not JSON - returning empty");
                empty()
            }
        },
        None => {
            println!("[IntroDB Media] request failed - returning empty");
            empty()
        }
    }
}

// ── /proxy/subtitle ──────────────────────────────────────────────────────────

#[derive(Debug, Deserialize)]
pub struct SubtitleQuery {
    url: Option<String>,
}

/// Hosts this proxy will fetch from.
///
/// The guard matters: without it this endpoint is an open proxy that will
/// fetch any URL on the caller's behalf, from a server whose IP the providers
/// trust.
const ALLOWED_HOSTS: &[&str] = &[
    "googlevideo.com",
    "youtube.com",
    "ytimg.com",
    "ggpht.com",
    "googleusercontent.com",
];

/// True only for the host itself or a real subdomain of it.
///
/// The JS uses `host.endsWith(d)`, which also accepts `evilgooglevideo.com` —
/// anyone can register that and use this endpoint as an open proxy. Requiring
/// either an exact match or a leading dot closes that.
fn host_allowed(host: &str) -> bool {
    let host = host.trim_end_matches('.').to_ascii_lowercase();
    ALLOWED_HOSTS.iter().any(|d| {
        host == *d || host.ends_with(&format!(".{d}"))
    })
}

pub async fn subtitle(headers: HeaderMap, Query(q): Query<SubtitleQuery>) -> Response {
    let Some(raw) = q.url.filter(|u| !u.is_empty()) else {
        return (StatusCode::BAD_REQUEST, "Missing ?url= parameter").into_response();
    };

    // Already decoded once by the query parser; some callers double-encode.
    let decoded = urlencoding::decode(&raw)
        .map(|s| s.into_owned())
        .unwrap_or_else(|_| raw.clone());

    let Ok(target) = reqwest::Url::parse(&decoded) else {
        return (StatusCode::BAD_REQUEST, "Invalid URL").into_response();
    };

    match target.host_str() {
        Some(h) if host_allowed(h) => {}
        _ => return (StatusCode::FORBIDDEN, "Host not allowed").into_response(),
    }

    let extra = [
        ("User-Agent", "Mozilla/5.0 (compatible; PStreamProxy/2.0)"),
        ("Accept", "text/vtt,text/*,*/*"),
    ];

    match get_text_with(&GIGA, target.as_str(), Duration::from_secs(8), &extra).await {
        Some(body) => (
            StatusCode::OK,
            [
                (header::CONTENT_TYPE, "text/vtt; charset=utf-8"),
                (header::ACCESS_CONTROL_ALLOW_ORIGIN, "*"),
                (header::CACHE_CONTROL, "public, max-age=300"),
            ],
            body,
        )
            .into_response(),
        None => (StatusCode::BAD_GATEWAY, "Subtitle fetch failed").into_response(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn accepts_the_host_itself_and_real_subdomains() {
        assert!(host_allowed("youtube.com"));
        assert!(host_allowed("rr3---sn-abc.googlevideo.com"));
        assert!(host_allowed("i.ytimg.com"));
        // Trailing dot is a valid absolute FQDN and resolves the same.
        assert!(host_allowed("youtube.com."));
        assert!(host_allowed("YouTube.COM"));
    }

    #[test]
    fn rejects_lookalikes_that_the_js_endswith_check_lets_through() {
        // These all pass `host.endsWith('googlevideo.com')` in the JS.
        assert!(!host_allowed("evilgooglevideo.com"));
        assert!(!host_allowed("notyoutube.com"));
        assert!(!host_allowed("myggpht.com"));
        // And the ordinary case.
        assert!(!host_allowed("attacker.example"));
        assert!(!host_allowed("youtube.com.attacker.example"));
    }
}
