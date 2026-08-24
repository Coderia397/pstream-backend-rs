//! Route handlers, grouped by what they depend on.
//!
//! `stateless` is done — those routes need only the shared crate. The rest are
//! grouped by the subsystem that has to land first (Redis, Supabase, the
//! torrent engine), and are declared in main.rs answering 501 until then.

pub mod passthrough;
pub mod stateless;
