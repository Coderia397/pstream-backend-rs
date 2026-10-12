# Streams mail

Sends the account emails (through Supabase's Send Email Hook) and, later, the profile emails, each in the reader's language, from
`no-reply@streams.watch` through Brevo's HTTP API.

* `core/`   logic with no network, tested with `cargo test -p streams-mail-core`
* `worker/` the Cloudflare Worker (`worker-build`)
* `bundles/` email wording per language, made by `python3 build_bundles.py` from the shared translations (`email-*` in `streams-frontend-rs/i18n`)
* `worker_config.json` names and addresses (no secrets); secrets are read from `~/.config/streams/*.env` by `deploy.py`
* `python3 deploy.py` builds, uploads and attaches `mail.streams.watch`

Design and decisions: `notes/36-localized-emails-and-rename-plan-2026-10-12.md`.
