//! Writes one email: subject, HTML and plain text, in the language asked for. The wording comes from the translation bundles;
//! the layout is the Streams one (black header with the logo, white card, one button, a footer), with dark mode styles and a
//! right to left page for Arabic.
use crate::bundle::{is_rtl, pick_language, text};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    Confirm,
    Recovery,
    Code,
    EmailChange,
    Invite,
    Reauth,
    Device,
}

impl Kind {
    /// The part of the message names that belong to this email: email-<part>-subject, -title, -body, -button.
    fn part(self) -> &'static str {
        match self {
            Kind::Confirm => "confirm",
            Kind::Recovery => "recovery",
            Kind::Code => "code",
            Kind::EmailChange => "change",
            Kind::Invite => "invite",
            Kind::Reauth => "reauth",
            Kind::Device => "device",
        }
    }
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Device {
    pub browser: String,
    pub system: String,
    pub country: Option<String>,
    pub time: String,
}

/// What one email needs to be written.
#[derive(Clone, Debug)]
pub struct Request {
    pub kind: Kind,
    pub lang: String,
    pub to: String,
    pub name: Option<String>,
    /// Set for a profile email: the greeting names the profile.
    pub profile: Option<String>,
    pub link: Option<String>,
    pub code: Option<String>,
    pub minutes: u32,
    pub new_email: Option<String>,
    pub device: Option<Device>,
}

/// The name, address and look that never change between emails.
pub struct Brand<'a> {
    pub name: &'a str,
    pub help_email: &'a str,
    pub site_url: &'a str,
    pub help_url: &'a str,
}

pub struct Rendered {
    pub subject: String,
    pub html: String,
    pub text: String,
}

/// Text made safe to put inside HTML.
pub fn escape(s: &str) -> String {
    s.chars().fold(String::with_capacity(s.len()), |mut out, c| {
        match c {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            '\'' => out.push_str("&#39;"),
            _ => out.push(c),
        }
        out
    })
}

pub fn render(brand: &Brand, req: &Request) -> Rendered {
    let lang = pick_language(&req.lang);
    let part = req.kind.part();
    let minutes = req.minutes.to_string();
    let new_email = req.new_email.clone().unwrap_or_default();
    let device = req.device.clone().unwrap_or_default();
    let where_ = device.country.as_ref().map(|c| text(lang, "email-device-where", &[("country", c)])).unwrap_or_default();
    let vars: Vec<(&str, &str)> = vec![
        ("brand", brand.name),
        ("help_email", brand.help_email),
        ("minutes", &minutes),
        ("new_email", &new_email),
        ("browser", &device.browser),
        ("system", &device.system),
        ("time", &device.time),
        ("where", &where_),
        ("profile", req.profile.as_deref().unwrap_or("")),
    ];
    let t = |key: &str| text(lang, key, &vars);
    let subject = t(&format!("email-{part}-subject"));
    let title = t(&format!("email-{part}-title"));
    let body = t(&format!("email-{part}-body"));
    let greeting = match &req.name {
        Some(n) => text(lang, "email-greeting", &[("name", n)]),
        None => t("email-greeting-plain"),
    };
    let for_profile = req.profile.as_ref().map(|p| text(lang, "email-for-profile", &[("profile", p)]));
    let button = req.link.as_ref().filter(|_| !matches!(req.kind, Kind::Reauth)).map(|l| (t(&format!("email-{part}-button")), l.clone()));
    let fallback = t("email-button-fallback");
    let ignore = t("email-ignore");
    let footer = t("email-footer");
    let help_center = t("email-help-center");
    let code_hint = (req.kind == Kind::Code && req.link.is_some()).then(|| t("email-code-or-link"));

    // plain text
    let mut plain = format!("{title}\n\n{greeting}\n");
    if let Some(p) = &for_profile {
        plain.push_str(&format!("{p}\n"));
    }
    plain.push_str(&format!("\n{body}\n"));
    if let Some(c) = &req.code {
        plain.push_str(&format!("\n{c}\n"));
    }
    if let Some(h) = &code_hint {
        plain.push_str(&format!("\n{h}\n"));
    }
    if let Some((label, link)) = &button {
        plain.push_str(&format!("\n{label}: {link}\n"));
    }
    plain.push_str(&format!("\n{ignore}\n\n{footer}\n"));

    // HTML
    let dir = if is_rtl(lang) { "rtl" } else { "ltr" };
    let align = if dir == "rtl" { "right" } else { "left" };
    let font = "-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif";
    let mut inner = format!(
        "<h1 class=\"ink\" style=\"margin:0 0 14px;font-size:24px;line-height:1.25;font-weight:700;color:#0b0b0c;\">{}</h1>\
         <p class=\"body\" style=\"margin:0 0 6px;font-size:16px;line-height:1.55;color:#3a3a3d;\">{}</p>",
        escape(&title),
        escape(&greeting)
    );
    if let Some(p) = &for_profile {
        inner.push_str(&format!("<p class=\"muted\" style=\"margin:0 0 6px;font-size:14px;line-height:1.5;color:#6b6b70;\">{}</p>", escape(p)));
    }
    inner.push_str(&format!("<p class=\"body\" style=\"margin:14px 0 22px;font-size:16px;line-height:1.55;color:#3a3a3d;\">{}</p>", escape(&body)));
    if let Some(c) = &req.code {
        inner.push_str(&format!(
            "<p class=\"ink\" dir=\"ltr\" style=\"margin:0 0 22px;font-size:32px;line-height:1.2;font-weight:700;letter-spacing:6px;color:#0b0b0c;text-align:{align};\">{}</p>",
            escape(c)
        ));
    }
    if let Some(h) = &code_hint {
        inner.push_str(&format!("<p class=\"body\" style=\"margin:0 0 18px;font-size:16px;line-height:1.55;color:#3a3a3d;\">{}</p>", escape(h)));
    }
    if let Some((label, link)) = &button {
        let href = escape(link);
        inner.push_str(&format!(
            "<table role=\"presentation\" cellpadding=\"0\" cellspacing=\"0\"><tr><td style=\"background:#2f6bff;border-radius:8px;\">\
             <a href=\"{href}\" style=\"display:inline-block;padding:14px 28px;font-size:16px;font-weight:700;color:#ffffff;text-decoration:none;font-family:{font};\">{}</a></td></tr></table>\
             <p class=\"muted\" style=\"margin:22px 0 0;font-size:13px;line-height:1.5;color:#6b6b70;\">{}<br><a href=\"{href}\" style=\"color:#6b6b70;word-break:break-all;\">{href}</a></p>",
            escape(label),
            escape(&fallback)
        ));
    }
    inner.push_str(&format!("<p class=\"muted\" style=\"margin:22px 0 0;font-size:13px;line-height:1.5;color:#6b6b70;\">{}</p>", escape(&ignore)));
    let logo = format!("{}/assets/email/logo-white@2x.png", brand.site_url.trim_end_matches('/'));
    let footer_html = escape(&footer).replace(&escape(&help_center), &format!("<a href=\"{}\" style=\"color:#8a8a8f;\">{}</a>", escape(brand.help_url), escape(&help_center)));
    let html = format!(
        "<!doctype html><html lang=\"{lang}\" dir=\"{dir}\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><meta name=\"color-scheme\" content=\"light dark\">\
         <style>@media (prefers-color-scheme: dark){{.bg-page{{background:#0b0b0c!important}}.card{{background:#16161a!important}}.ink{{color:#f3f1ec!important}}.body{{color:#d6d6da!important}}.muted{{color:#a8a8ad!important}}.rule{{border-color:#2a2a2e!important}}}}\
         @media only screen and (max-width:600px){{.pad{{padding-left:22px!important;padding-right:22px!important}}}}</style></head>\
         <body class=\"bg-page\" style=\"margin:0;padding:0;background:#f3f1ec;\"><table role=\"presentation\" width=\"100%\" cellpadding=\"0\" cellspacing=\"0\" class=\"bg-page\" style=\"background:#f3f1ec;\"><tr><td align=\"center\" style=\"padding:32px 16px;\">\
         <table role=\"presentation\" width=\"560\" cellpadding=\"0\" cellspacing=\"0\" class=\"card\" style=\"width:100%;max-width:560px;background:#ffffff;border-radius:14px;overflow:hidden;\">\
         <tr><td align=\"center\" style=\"background:#0b0b0c;padding:30px 24px;\"><a href=\"{site}\"><img src=\"{logo}\" width=\"150\" alt=\"{brand}\" style=\"display:block;border:0;\"></a></td></tr>\
         <tr><td class=\"pad ink\" dir=\"{dir}\" style=\"padding:36px 36px 28px;font-family:{font};color:#0b0b0c;text-align:{align};\">{inner}</td></tr>\
         <tr><td class=\"pad muted rule\" dir=\"{dir}\" style=\"padding:24px 36px 30px;font-family:{font};font-size:12px;line-height:1.6;color:#8a8a8f;border-top:1px solid #ececf0;text-align:{align};\">{footer_html}</td></tr>\
         </table></td></tr></table></body></html>",
        site = escape(brand.site_url),
        brand = escape(brand.name),
    );
    Rendered { subject, html, text: plain }
}

#[cfg(test)]
mod tests {
    use super::*;

    const BRAND: Brand = Brand { name: "Streams", help_email: "help@streams.watch", site_url: "https://streams.watch", help_url: "https://streams.watch/help" };

    fn request(kind: Kind, lang: &str) -> Request {
        Request { kind, lang: lang.into(), to: "a@b.co".into(), name: Some("Ada".into()), profile: None, link: Some("https://streams.watch/auth/confirm?token_hash=abc&type=signup".into()), code: None, minutes: 10, new_email: None, device: None }
    }

    #[test]
    fn a_confirmation_email_has_subject_button_link_and_footer() {
        let r = render(&BRAND, &request(Kind::Confirm, "en"));
        assert_eq!(r.subject, "Confirm your email address");
        assert!(r.html.contains("href=\"https://streams.watch/auth/confirm?token_hash=abc&amp;type=signup\""));
        assert!(r.text.contains("https://streams.watch/auth/confirm?token_hash=abc&type=signup"));
        assert!(r.html.contains("Hello Ada,") && r.html.contains("help@streams.watch"));
        assert!(r.html.contains("href=\"https://streams.watch/help\""), "the Help Center words in the footer are a link");
    }

    #[test]
    fn a_code_email_shows_the_code_and_when_it_expires() {
        let mut q = request(Kind::Code, "en");
        q.code = Some("482913".into());
        let r = render(&BRAND, &q);
        assert!(r.html.contains("482913") && r.text.contains("482913"));
        assert!(r.text.contains("10 minutes"));
    }

    #[test]
    fn reauthentication_has_no_button() {
        let mut q = request(Kind::Reauth, "en");
        q.code = Some("111222".into());
        let r = render(&BRAND, &q);
        assert!(!r.html.contains("<a href=\"https://streams.watch/auth/confirm"));
        assert!(r.html.contains("111222"));
    }

    #[test]
    fn a_profile_email_names_the_profile() {
        let mut q = request(Kind::Device, "en");
        q.profile = Some("Kids".into());
        q.device = Some(Device { browser: "Chrome 156".into(), system: "Mac".into(), country: Some("GB".into()), time: "12 Oct 2026, 07:20".into() });
        let r = render(&BRAND, &q);
        assert!(r.text.contains("Kids") && r.text.contains("Chrome 156 on Mac") && r.text.contains("from GB"));
    }

    #[test]
    fn arabic_is_written_right_to_left_and_values_are_escaped() {
        let mut q = request(Kind::Confirm, "ar");
        q.name = Some("<b>Ada</b>".into());
        let r = render(&BRAND, &q);
        assert!(r.html.contains("dir=\"rtl\"") && r.html.contains("lang=\"ar\""));
        assert!(r.html.contains("&lt;b&gt;Ada&lt;/b&gt;") && !r.html.contains("<b>Ada</b>"));
    }

    #[test]
    fn an_unknown_language_is_english() {
        assert_eq!(render(&BRAND, &request(Kind::Confirm, "xx")).subject, "Confirm your email address");
    }
}
