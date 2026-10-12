//! Streams mail, the part with no network: which language to write in, the wording from the shared translations, the layout of
//! the message, the check of Supabase's webhook signature and the reading of the hook payload.
pub mod bundle;
pub mod hook;
pub mod render;
pub mod webhook;
