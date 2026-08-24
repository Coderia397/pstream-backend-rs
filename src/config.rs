//! Runtime configuration, read once at startup.
//!
//! Everything is optional. The JS reads `process.env` lazily at each call
//! site, so a missing variable disables one feature rather than stopping the
//! server — a Space with no Redis still serves the stateless routes. Same
//! behaviour here: absent means "that subsystem is off", not "fail to boot".

use std::env;

#[derive(Debug, Clone)]
pub struct Config {
    pub port: u16,

    /// Provider health and caches. Without it those degrade to in-memory.
    pub redis_url: Option<String>,

    /// PostgREST endpoint plus service key, for the profile/sync routes.
    pub supabase_url: Option<String>,
    pub supabase_key: Option<String>,

    /// Signing key for the session tokens issued by /api/auth/verify.
    pub jwt_secret: Option<String>,

    /// Search-only key; subtitle files themselves are public URLs.
    pub subdl_api_key: Option<String>,

    pub alldebrid_api_key: Option<String>,

    /// Residential egress for providers that block datacenter ranges.
    pub residential_proxy_url: Option<String>,

    /// Gates the admin page. Unset means the page is refused outright.
    pub admin_token: Option<String>,
}

fn var(key: &str) -> Option<String> {
    match env::var(key) {
        Ok(v) if !v.trim().is_empty() => Some(v),
        _ => None,
    }
}

impl Config {
    pub fn from_env() -> Self {
        // Loads .env when present; absence is not an error in a container
        // where the platform injects real environment variables.
        let _ = dotenvy::dotenv();

        Self {
            port: var("PORT").and_then(|p| p.parse().ok()).unwrap_or(7860),
            redis_url: var("REDIS_URL"),
            supabase_url: var("SUPABASE_URL"),
            supabase_key: var("SUPABASE_SERVICE_KEY").or_else(|| var("SUPABASE_KEY")),
            jwt_secret: var("JWT_SECRET"),
            subdl_api_key: var("SUBDL_API_KEY"),
            alldebrid_api_key: var("ALLDEBRID_API_KEY"),
            residential_proxy_url: var("RESIDENTIAL_PROXY_URL"),
            admin_token: var("ADMIN_TOKEN"),
        }
    }

    /// One line per subsystem at boot, so a misconfigured Space is obvious
    /// from the logs rather than from a route failing hours later.
    pub fn log_summary(&self) {
        let state = |o: &Option<String>| if o.is_some() { "configured" } else { "OFF" };
        println!("[config] port                  {}", self.port);
        println!("[config] redis                 {}", state(&self.redis_url));
        println!("[config] supabase              {}", state(&self.supabase_url));
        println!("[config] jwt                   {}", state(&self.jwt_secret));
        println!("[config] subdl                 {}", state(&self.subdl_api_key));
        println!("[config] alldebrid             {}", state(&self.alldebrid_api_key));
        println!("[config] residential proxy     {}", state(&self.residential_proxy_url));
        println!("[config] admin                 {}", state(&self.admin_token));
    }
}
