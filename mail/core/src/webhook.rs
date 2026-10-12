//! Checks that a request really comes from Supabase. Supabase signs the Send Email Hook with the Standard Webhooks scheme: the
//! headers `webhook-id`, `webhook-timestamp` and `webhook-signature` ("v1,<base64>", possibly several separated by spaces), the
//! signature being HMAC-SHA256 over "<id>.<timestamp>.<body>" with the secret from the hook settings ("v1,whsec_<base64>").
use base64::{engine::general_purpose::STANDARD, Engine};
use hmac::{Hmac, Mac};
use sha2::Sha256;

/// How far the signed time may be from now, in seconds.
pub const TOLERANCE_SECONDS: i64 = 300;

#[derive(Debug, PartialEq, Eq)]
pub enum Refused {
    Secret,
    Timestamp,
    Signature,
}

/// The raw key bytes from a secret written as "v1,whsec_<base64>" or "whsec_<base64>".
fn key(secret: &str) -> Result<Vec<u8>, Refused> {
    let encoded = secret.rsplit("whsec_").next().filter(|_| secret.contains("whsec_")).ok_or(Refused::Secret)?;
    STANDARD.decode(encoded.trim()).map_err(|_| Refused::Secret)
}

fn sign(key: &[u8], id: &str, timestamp: &str, body: &str) -> Vec<u8> {
    let mut mac = Hmac::<Sha256>::new_from_slice(key).expect("an HMAC key can be any length");
    mac.update(format!("{id}.{timestamp}.{body}").as_bytes());
    mac.finalize().into_bytes().to_vec()
}

/// The signature header a sender would write for this message (used by the tests, and to try the endpoint by hand).
pub fn signature_header(secret: &str, id: &str, timestamp: &str, body: &str) -> Result<String, Refused> {
    Ok(format!("v1,{}", STANDARD.encode(sign(&key(secret)?, id, timestamp, body))))
}

/// Accepts the request only when the time is close to `now` and one of the signatures matches.
pub fn verify(secret: &str, id: &str, timestamp: &str, signature_header: &str, body: &str, now: i64) -> Result<(), Refused> {
    let key = key(secret)?;
    let sent: i64 = timestamp.trim().parse().map_err(|_| Refused::Timestamp)?;
    if (now - sent).abs() > TOLERANCE_SECONDS {
        return Err(Refused::Timestamp);
    }
    let expected = sign(&key, id, timestamp, body);
    for candidate in signature_header.split_whitespace() {
        let Some(b64) = candidate.strip_prefix("v1,") else { continue };
        let Ok(bytes) = STANDARD.decode(b64) else { continue };
        let mut mac = Hmac::<Sha256>::new_from_slice(&key).expect("an HMAC key can be any length");
        mac.update(format!("{id}.{timestamp}.{body}").as_bytes());
        // constant time comparison inside verify_slice
        if mac.verify_slice(&bytes).is_ok() && bytes == expected {
            return Ok(());
        }
    }
    Err(Refused::Signature)
}

#[cfg(test)]
mod tests {
    use super::*;

    const SECRET: &str = "v1,whsec_c2VjcmV0LWtleS1mb3ItdGVzdGluZy1vbmx5";

    #[test]
    fn a_signed_request_is_accepted() {
        let header = signature_header(SECRET, "msg_1", "1000000", "{\"a\":1}").unwrap();
        assert_eq!(verify(SECRET, "msg_1", "1000000", &header, "{\"a\":1}", 1_000_010), Ok(()));
    }

    #[test]
    fn a_changed_body_is_refused() {
        let header = signature_header(SECRET, "msg_1", "1000000", "{\"a\":1}").unwrap();
        assert_eq!(verify(SECRET, "msg_1", "1000000", &header, "{\"a\":2}", 1_000_010), Err(Refused::Signature));
    }

    #[test]
    fn another_secret_is_refused() {
        let header = signature_header("whsec_b3RoZXI=", "msg_1", "1000000", "x").unwrap();
        assert_eq!(verify(SECRET, "msg_1", "1000000", &header, "x", 1_000_000), Err(Refused::Signature));
    }

    #[test]
    fn an_old_or_future_request_is_refused() {
        let header = signature_header(SECRET, "msg_1", "1000000", "x").unwrap();
        assert_eq!(verify(SECRET, "msg_1", "1000000", &header, "x", 1_000_000 + TOLERANCE_SECONDS + 1), Err(Refused::Timestamp));
        assert_eq!(verify(SECRET, "msg_1", "1000000", &header, "x", 1_000_000 - TOLERANCE_SECONDS - 1), Err(Refused::Timestamp));
        assert_eq!(verify(SECRET, "msg_1", "abc", &header, "x", 1), Err(Refused::Timestamp));
    }

    #[test]
    fn several_signatures_may_be_sent_and_one_must_match() {
        let good = signature_header(SECRET, "m", "5", "b").unwrap();
        let header = format!("v1,AAAA {good}");
        assert_eq!(verify(SECRET, "m", "5", &header, "b", 5), Ok(()));
        assert_eq!(verify(SECRET, "m", "5", "v2,AAAA", "b", 5), Err(Refused::Signature));
    }

    #[test]
    fn a_secret_without_the_prefix_is_refused() {
        assert_eq!(verify("not-a-secret", "m", "5", "v1,AA", "b", 5), Err(Refused::Secret));
    }
}
