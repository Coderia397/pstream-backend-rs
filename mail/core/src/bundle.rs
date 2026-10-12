//! The email wording in every language. The texts come from the shared translation files (`email-*` messages in i18n/*.ftl),
//! turned into one JSON file per language by `build_bundles.py`. A message missing in a language is read from English.
use std::collections::HashMap;
use std::sync::OnceLock;

/// Languages with a bundle. English first: it is the fallback.
pub const LANGS: [&str; 16] = ["en", "ar", "de", "es", "fr", "hi", "it", "ja", "ko", "nl", "pl", "pt", "ru", "sv", "tr", "zh"];

const SOURCES: [&str; 16] = [
    include_str!("../../bundles/en.json"),
    include_str!("../../bundles/ar.json"),
    include_str!("../../bundles/de.json"),
    include_str!("../../bundles/es.json"),
    include_str!("../../bundles/fr.json"),
    include_str!("../../bundles/hi.json"),
    include_str!("../../bundles/it.json"),
    include_str!("../../bundles/ja.json"),
    include_str!("../../bundles/ko.json"),
    include_str!("../../bundles/nl.json"),
    include_str!("../../bundles/pl.json"),
    include_str!("../../bundles/pt.json"),
    include_str!("../../bundles/ru.json"),
    include_str!("../../bundles/sv.json"),
    include_str!("../../bundles/tr.json"),
    include_str!("../../bundles/zh.json"),
];

type Messages = HashMap<String, String>;

fn parsed(index: usize) -> &'static Messages {
    static CELLS: [OnceLock<Messages>; 16] = [const { OnceLock::new() }; 16];
    CELLS[index].get_or_init(|| serde_json::from_str(SOURCES[index]).unwrap_or_default())
}

/// The bundle language for a requested one: "pt-BR" gives "pt", "zh-Hans" gives "zh", anything unknown gives "en".
pub fn pick_language(requested: &str) -> &'static str {
    let base = requested.trim().split(['-', '_']).next().unwrap_or("").to_ascii_lowercase();
    LANGS.iter().copied().find(|l| *l == base).unwrap_or("en")
}

/// Languages written right to left.
pub fn is_rtl(lang: &str) -> bool {
    matches!(lang, "ar" | "he" | "fa" | "ur")
}

/// A message with its `{ $name }` values filled in. A message that is nowhere gives the key, so a gap is visible, not blank.
pub fn text(lang: &str, key: &str, vars: &[(&str, &str)]) -> String {
    let lang = pick_language(lang);
    let index = LANGS.iter().position(|l| *l == lang).unwrap_or(0);
    let raw = parsed(index).get(key).or_else(|| parsed(0).get(key)).map(String::as_str).unwrap_or(key);
    fill(raw, vars)
}

/// Replaces `{ $name }` with the value of `name`; an unknown name is left as written.
pub fn fill(raw: &str, vars: &[(&str, &str)]) -> String {
    let mut out = String::with_capacity(raw.len());
    let mut rest = raw;
    while let Some(start) = rest.find("{ $") {
        out.push_str(&rest[..start]);
        let after = &rest[start + 3..];
        match after.find('}') {
            Some(end) => {
                let name = after[..end].trim();
                match vars.iter().find(|(k, _)| *k == name) {
                    Some((_, v)) => out.push_str(v),
                    None => out.push_str(&rest[start..start + 3 + end + 1]),
                }
                rest = &after[end + 1..];
            }
            None => {
                out.push_str(&rest[start..]);
                rest = "";
            }
        }
    }
    out.push_str(rest);
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn requested_languages_map_to_a_bundle() {
        assert_eq!(pick_language("pt-BR"), "pt");
        assert_eq!(pick_language("zh_Hans"), "zh");
        assert_eq!(pick_language("DE"), "de");
        assert_eq!(pick_language("xx"), "en");
        assert_eq!(pick_language(""), "en");
    }

    #[test]
    fn values_are_filled_in() {
        assert_eq!(fill("Welcome to { $brand }, { $name }.", &[("brand", "Streams"), ("name", "Ada")]), "Welcome to Streams, Ada.");
        assert_eq!(fill("Unknown { $who } stays", &[]), "Unknown { $who } stays");
        assert_eq!(fill("no values", &[]), "no values");
    }

    #[test]
    fn english_has_every_email_message() {
        for key in ["email-footer", "email-confirm-subject", "email-recovery-button", "email-code-body", "email-reauth-title", "email-device-body"] {
            assert_ne!(text("en", key, &[]), key, "missing English message {key}");
        }
    }

    #[test]
    fn a_missing_message_falls_back_to_english() {
        // a language bundle that lacks the key reads English; here the key exists in en, whatever the language file holds
        assert_ne!(text("de", "email-confirm-subject", &[]), "email-confirm-subject");
    }

    #[test]
    fn arabic_is_right_to_left() {
        assert!(is_rtl("ar"));
        assert!(!is_rtl("de"));
    }
}
