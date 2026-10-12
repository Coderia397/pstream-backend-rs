//! Reads what Supabase's Send Email Hook sends and says which messages to write. The link in every email goes to our own
//! confirm page on the site address, with the token hash and the kind; the language is the one saved in the user's data
//! (`user_metadata.lang`, set at sign up and when the display language changes), English when there is none.
use crate::render::{Kind, Request};
use serde::Deserialize;

#[derive(Debug, Deserialize)]
pub struct Hook {
    pub user: User,
    pub email_data: EmailData,
}

#[derive(Debug, Deserialize)]
pub struct User {
    pub email: String,
    #[serde(default)]
    pub new_email: Option<String>,
    #[serde(default)]
    pub user_metadata: serde_json::Value,
}

#[derive(Debug, Deserialize)]
pub struct EmailData {
    #[serde(default)]
    pub token: String,
    #[serde(default)]
    pub token_hash: String,
    #[serde(default)]
    pub token_new: String,
    #[serde(default)]
    pub token_hash_new: String,
    pub email_action_type: String,
}

#[derive(Debug, PartialEq, Eq)]
pub enum Unsupported {
    Action(String),
}

fn link(site_url: &str, hash: &str, kind: &str) -> String {
    format!("{}/auth/confirm?token_hash={}&type={}", site_url.trim_end_matches('/'), hash, kind)
}

/// The messages for one hook call: one, or two for an email change that must be confirmed at both addresses.
pub fn requests(hook: &Hook, site_url: &str, code_minutes: u32) -> Result<Vec<Request>, Unsupported> {
    let meta = &hook.user.user_metadata;
    let lang = meta.get("lang").and_then(|v| v.as_str()).unwrap_or("en").to_string();
    let name = meta.get("first_name").and_then(|v| v.as_str()).filter(|s| !s.trim().is_empty()).map(|s| s.trim().to_string());
    let base = |kind: Kind, to: &str| Request { kind, lang: lang.clone(), to: to.to_string(), name: name.clone(), profile: None, link: None, code: None, minutes: code_minutes, new_email: None, device: None };
    let d = &hook.email_data;
    let make = |kind: Kind, to: &str, hash: &str, type_name: &str| Request { link: Some(link(site_url, hash, type_name)), ..base(kind, to) };
    Ok(match d.email_action_type.as_str() {
        "signup" => vec![make(Kind::Confirm, &hook.user.email, &d.token_hash, "signup")],
        "invite" => vec![make(Kind::Invite, &hook.user.email, &d.token_hash, "invite")],
        "recovery" => vec![make(Kind::Recovery, &hook.user.email, &d.token_hash, "recovery")],
        // a sign in by one time code: the code and the link in one message
        "magiclink" => vec![Request { code: Some(d.token.clone()), ..make(Kind::Code, &hook.user.email, &d.token_hash, "magiclink") }],
        "reauthentication" => vec![Request { code: Some(d.token.clone()), ..base(Kind::Reauth, &hook.user.email) }],
        "email_change" => {
            let mut out = Vec::new();
            let new_email = hook.user.new_email.clone();
            // the address in use confirms with its own hash, the new one with the "new" hash; either can be absent
            if !d.token_hash.is_empty() {
                out.push(Request { new_email: new_email.clone(), ..make(Kind::EmailChange, &hook.user.email, &d.token_hash, "email_change") });
            }
            if let (false, Some(to)) = (d.token_hash_new.is_empty(), new_email.as_deref()) {
                out.push(Request { new_email: Some(to.to_string()), ..make(Kind::EmailChange, to, &d.token_hash_new, "email_change") });
            }
            out
        }
        other => return Err(Unsupported::Action(other.to_string())),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn hook(json: &str) -> Hook {
        serde_json::from_str(json).unwrap()
    }

    #[test]
    fn a_signup_goes_to_our_confirm_page_in_the_saved_language() {
        let h = hook(r#"{"user":{"email":"a@b.co","user_metadata":{"lang":"de","first_name":"Ada"}},"email_data":{"token":"123456","token_hash":"abc","email_action_type":"signup"}}"#);
        let r = requests(&h, "https://streams.watch/", 10).unwrap();
        assert_eq!(r.len(), 1);
        assert_eq!((r[0].lang.as_str(), r[0].to.as_str(), r[0].name.as_deref()), ("de", "a@b.co", Some("Ada")));
        assert_eq!(r[0].link.as_deref(), Some("https://streams.watch/auth/confirm?token_hash=abc&type=signup"));
    }

    #[test]
    fn no_saved_language_means_english() {
        let h = hook(r#"{"user":{"email":"a@b.co"},"email_data":{"token_hash":"x","email_action_type":"recovery"}}"#);
        assert_eq!(requests(&h, "https://streams.watch", 10).unwrap()[0].lang, "en");
    }

    #[test]
    fn a_one_time_code_carries_the_code_and_the_link() {
        let h = hook(r#"{"user":{"email":"a@b.co"},"email_data":{"token":"654321","token_hash":"h","email_action_type":"magiclink"}}"#);
        let r = &requests(&h, "https://streams.watch", 10).unwrap()[0];
        assert_eq!((r.code.as_deref(), r.kind), (Some("654321"), Kind::Code));
        assert!(r.link.as_deref().unwrap().ends_with("type=magiclink"));
    }

    #[test]
    fn reauthentication_is_a_code_only() {
        let h = hook(r#"{"user":{"email":"a@b.co"},"email_data":{"token":"111222","email_action_type":"reauthentication"}}"#);
        let r = &requests(&h, "https://streams.watch", 10).unwrap()[0];
        assert!(r.link.is_none() && r.code.as_deref() == Some("111222"));
    }

    #[test]
    fn an_email_change_can_go_to_both_addresses() {
        let h = hook(r#"{"user":{"email":"old@b.co","new_email":"new@b.co"},"email_data":{"token_hash":"h1","token_hash_new":"h2","email_action_type":"email_change"}}"#);
        let r = requests(&h, "https://streams.watch", 10).unwrap();
        assert_eq!(r.iter().map(|x| x.to.as_str()).collect::<Vec<_>>(), ["old@b.co", "new@b.co"]);
        assert!(r[1].link.as_deref().unwrap().contains("token_hash=h2"));
    }

    #[test]
    fn an_unknown_action_is_reported() {
        let h = hook(r#"{"user":{"email":"a@b.co"},"email_data":{"email_action_type":"surprise"}}"#);
        assert_eq!(requests(&h, "https://streams.watch", 10).unwrap_err(), Unsupported::Action("surprise".into()));
    }
}
