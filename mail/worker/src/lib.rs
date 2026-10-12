//! The Streams mail Worker. It receives Supabase's Send Email Hook, checks the signature, writes the email in the language saved
//! for the user and sends it through Brevo's HTTP API. Settings come from the Worker's variables and secrets, none are written here:
//!   variables: BRAND_NAME, SITE_URL, HELP_URL, HELP_EMAIL, SENDER_EMAIL, CODE_MINUTES
//!   secrets:   HOOK_SECRET (the Supabase hook secret), BREVO_API_KEY
use serde_json::json;
use streams_mail_core::{
    hook::{self, Hook},
    render::{self, Brand},
    webhook,
};
use worker::*;

fn var(env: &Env, name: &str) -> Result<String> {
    env.var(name).map(|v| v.to_string())
}

/// Supabase expects this shape when a hook refuses.
fn refuse(status: u16, message: &str) -> Result<Response> {
    Response::from_json(&json!({ "error": { "http_code": status, "message": message } })).map(|r| r.with_status(status))
}

async fn send(env: &Env, to: &str, rendered: &render::Rendered) -> Result<()> {
    let key = env.secret("BREVO_API_KEY")?.to_string();
    let body = json!({
        "sender": { "name": var(env, "BRAND_NAME")?, "email": var(env, "SENDER_EMAIL")? },
        "to": [{ "email": to }],
        "subject": rendered.subject,
        "htmlContent": rendered.html,
        "textContent": rendered.text,
    });
    let headers = Headers::new();
    headers.set("api-key", &key)?;
    headers.set("content-type", "application/json")?;
    headers.set("accept", "application/json")?;
    // Brevo sits behind Cloudflare, which refuses requests with no recognisable client name
    headers.set("user-agent", "streams-mail/1.0 (+https://streams.watch)")?;
    let mut init = RequestInit::new();
    init.with_method(Method::Post).with_headers(headers).with_body(Some(body.to_string().into()));
    let mut response = Fetch::Request(Request::new_with_init("https://api.brevo.com/v3/smtp/email", &init)?).send().await?;
    if !(200..300).contains(&response.status_code()) {
        let detail = response.text().await.unwrap_or_default();
        return Err(Error::RustError(format!("brevo answered {}: {}", response.status_code(), detail.chars().take(200).collect::<String>())));
    }
    Ok(())
}

async fn send_email_hook(mut req: Request, env: Env) -> Result<Response> {
    let body = req.text().await?;
    let header = |name: &str| req.headers().get(name).ok().flatten().unwrap_or_default();
    let secret = env.secret("HOOK_SECRET")?.to_string();
    let now = (Date::now().as_millis() / 1000) as i64;
    if webhook::verify(&secret, &header("webhook-id"), &header("webhook-timestamp"), &header("webhook-signature"), &body, now).is_err() {
        return refuse(401, "signature check failed");
    }
    let parsed: Hook = match serde_json::from_str(&body) {
        Ok(h) => h,
        Err(_) => return refuse(400, "unreadable hook payload"),
    };
    let site = var(&env, "SITE_URL")?;
    let minutes: u32 = var(&env, "CODE_MINUTES").ok().and_then(|m| m.parse().ok()).unwrap_or(10);
    let requests = match hook::requests(&parsed, &site, minutes) {
        Ok(r) if !r.is_empty() => r,
        Ok(_) => return Response::from_json(&json!({})),
        Err(hook::Unsupported::Action(a)) => return refuse(400, &format!("unsupported email type {a}")),
    };
    let name = var(&env, "BRAND_NAME")?;
    let help_email = var(&env, "HELP_EMAIL")?;
    let help_url = var(&env, "HELP_URL")?;
    let brand = Brand { name: &name, help_email: &help_email, site_url: &site, help_url: &help_url };
    for request in &requests {
        let rendered = render::render(&brand, request);
        if let Err(e) = send(&env, &request.to, &rendered).await {
            console_error!("send failed: {e}");
            return refuse(500, "the email could not be sent");
        }
    }
    Response::from_json(&json!({}))
}

#[event(fetch)]
async fn fetch(req: Request, env: Env, _ctx: Context) -> Result<Response> {
    let url = req.url()?;
    match (req.method(), url.path()) {
        (Method::Get, "/health") => Response::ok("ok"),
        (Method::Post, "/hook/send-email") => send_email_hook(req, env).await,
        _ => Response::error("not found", 404),
    }
}
