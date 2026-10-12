#!/usr/bin/env python3
"""Applies the Supabase Auth settings of Streams: the site address, the allowed redirect addresses, the code lifetime, the
password length, the email subjects and the branded email templates. It talks to the Supabase Management API.

  python3 apply_auth_config.py            shows what would change (nothing is written)
  python3 apply_auth_config.py --apply    writes the changes (add --smtp to also write the Brevo SMTP fallback)

The access token is read from the environment (SUPABASE_ACCESS_TOKEN) or from the file ~/.supabase/access-token, which is where
`supabase login` puts it. Create one at https://supabase.com/dashboard/account/tokens. It is never written anywhere by this script.
Sender settings (Brevo SMTP) are only sent when SMTP_USER and SMTP_PASS are in the environment (the Brevo SMTP login and SMTP
key); host, port, address and name are in auth_config.json.
"""
import json, os, pathlib, sys, urllib.request, urllib.error

HERE = pathlib.Path(__file__).resolve().parent
# Secrets live outside the project, in private files on this Mac (mode 600): ~/.config/streams/brevo.env (SMTP_USER, SMTP_PASS)
# and ~/.config/streams/supabase.env (SUPABASE_ACCESS_TOKEN). Values already in the environment win.
for name in ("brevo.env", "supabase.env", "cloudflare.env", "mail.env"):
    f = pathlib.Path.home() / ".config/streams" / name
    if f.exists():
        for line in f.read_text().splitlines():
            if "=" in line and not line.lstrip().startswith("#"):
                k, v = line.split("=", 1)
                os.environ.setdefault(k.strip(), v.strip())
cfg = json.loads((HERE / "auth_config.json").read_text())
ref = cfg["project_ref"]
token = os.environ.get("SUPABASE_ACCESS_TOKEN") or ((pathlib.Path.home() / ".supabase/access-token").read_text().strip() if (pathlib.Path.home() / ".supabase/access-token").exists() else "")
if not token:
    sys.exit("No access token. Set SUPABASE_ACCESS_TOKEN or put one in ~/.supabase/access-token (see the top of this file).")

def call(method, body=None):
    req = urllib.request.Request(f"https://api.supabase.com/v1/projects/{ref}/config/auth", method=method, data=json.dumps(body).encode() if body is not None else None,
                                 headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json", "User-Agent": "streams-auth-config"})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        sys.exit(f"{method} failed: {e.code} {e.read().decode()[:300]}")

want = {"site_url": cfg["site_url"], "uri_allow_list": cfg["uri_allow_list"], "password_min_length": cfg["password_min_length"], "mailer_otp_exp": cfg["mailer_otp_exp"]}
for kind, subject in cfg["subjects"].items():
    want[f"mailer_subjects_{kind}"] = subject
for kind, path in cfg["templates"].items():
    want[f"mailer_templates_{kind}_content"] = (HERE / path).resolve().read_text()
# Sender: host, port, address and name come from auth_config.json (Brevo); the login and the SMTP key are secrets and only come
# from the environment, never from a file in the project: SMTP_USER and SMTP_PASS.
if "--smtp" in sys.argv and os.environ.get("SMTP_USER") and os.environ.get("SMTP_PASS"):
    smtp = cfg["smtp"]
    want.update({"smtp_host": smtp["host"], "smtp_port": smtp["port"], "smtp_user": os.environ["SMTP_USER"], "smtp_pass": os.environ["SMTP_PASS"],
                 "smtp_admin_email": smtp["admin_email"], "smtp_sender_name": smtp["sender_name"]})

# Send Email Hook: Supabase hands every account email to our mail Worker (mail/), which writes it in the user's language and sends
# it through Resend. The address is in auth_config.json; the signing secret (HOOK_SECRET) only comes from the environment.
if cfg.get("hook") and os.environ.get("HOOK_SECRET"):
    want.update({"hook_send_email_enabled": True, "hook_send_email_uri": cfg["hook"]["uri"], "hook_send_email_secrets": os.environ["HOOK_SECRET"]})

current = call("GET")
changes = {k: v for k, v in want.items() if current.get(k) != v}
print(f"{len(changes)} of {len(want)} settings differ:")
for k, v in changes.items():
    shown = "(%d characters)" % len(v) if isinstance(v, str) and len(v) > 80 else ("(hidden)" if "pass" in k or "secret" in k else repr(v))
    print(f"  {k}: {shown}")
if "--apply" not in sys.argv:
    print("Nothing written. Run again with --apply to write these.")
elif changes:
    call("PATCH", changes)
    print("Written.")
