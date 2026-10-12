#!/usr/bin/env python3
"""Builds and deploys the mail Worker to Cloudflare through the API (no Node needed), attaches it to its own address, and sets its
variables and secrets. Safe to repeat.
  python3 deploy.py            build, upload, set variables and secrets, attach the address
Reads private files from ~/.config/streams: cloudflare.env (CF_EMAIL, CF_KEY, CF_ACCOUNT, CF_ZONE), brevo.env (BREVO_API_KEY) and
mail.env (HOOK_SECRET, made here the first time: paste it into Supabase, Authentication, Hooks, Send Email)."""
import base64, json, mimetypes, os, pathlib, secrets, subprocess, sys, urllib.request, urllib.error, uuid

HERE = pathlib.Path(__file__).resolve().parent
CONF = json.loads((HERE / "worker_config.json").read_text())
CFG = pathlib.Path.home() / ".config/streams"

def load(name):
    p = CFG / name
    return dict(l.split("=", 1) for l in p.read_text().splitlines() if "=" in l and not l.startswith("#")) if p.exists() else {}
cf, brevo, mail = load("cloudflare.env"), load("brevo.env"), load("mail.env")
if "HOOK_SECRET" not in mail:
    mail["HOOK_SECRET"] = "v1,whsec_" + base64.b64encode(secrets.token_bytes(32)).decode()
    p = CFG / "mail.env"
    p.write_text("# Secret shared with Supabase's Send Email Hook. Kept only on this Mac (mode 600).\nHOOK_SECRET=" + mail["HOOK_SECRET"] + "\n")
    p.chmod(0o600)
    print("made a new hook secret in ~/.config/streams/mail.env")

# 1. build
subprocess.run(["worker-build", "--release"], cwd=HERE / "worker", check=True)
build = HERE / "worker/build"
modules = [build / "index.js", build / "index_bg.wasm"]
print("built:", ", ".join(sorted(p.name for p in modules)))

# 2. upload as a module Worker with its variables and secrets
bindings = [{"type": "plain_text", "name": k, "text": v} for k, v in CONF["vars"].items()]
bindings += [{"type": "secret_text", "name": "HOOK_SECRET", "text": mail["HOOK_SECRET"]}, {"type": "secret_text", "name": "BREVO_API_KEY", "text": brevo["BREVO_API_KEY"]}]
metadata = {"main_module": "index.js", "compatibility_date": CONF["compatibility_date"], "bindings": bindings}
boundary = uuid.uuid4().hex
parts = [(f'name="metadata"', "application/json", json.dumps(metadata).encode())]
for p in modules:
    ctype = "application/wasm" if p.suffix == ".wasm" else "application/javascript+module"
    parts.append((f'name="{p.name}"; filename="{p.name}"', ctype, p.read_bytes()))
body = b"".join(f"--{boundary}\r\nContent-Disposition: form-data; {d}\r\nContent-Type: {t}\r\n\r\n".encode() + c + b"\r\n" for d, t, c in parts) + f"--{boundary}--\r\n".encode()

def call(method, path, data=None, ctype="application/json"):
    req = urllib.request.Request("https://api.cloudflare.com/client/v4" + path, method=method, data=data, headers={"X-Auth-Email": cf["CF_EMAIL"], "X-Auth-Key": cf["CF_KEY"], "Content-Type": ctype, "User-Agent": "curl/8.7.1"})
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            return json.loads(r.read())
    except urllib.error.HTTPError as e:
        return json.loads(e.read() or b"{}")
acct, zone = cf["CF_ACCOUNT"], cf["CF_ZONE"]
r = call("PUT", f"/accounts/{acct}/workers/scripts/{CONF['name']}", body, f"multipart/form-data; boundary={boundary}")
print("upload:", "ok" if r.get("success") else r.get("errors"))
if not r.get("success"): sys.exit(1)

# 3. its own address (Cloudflare creates the DNS record and certificate)
r = call("PUT", f"/accounts/{acct}/workers/domains", json.dumps({"hostname": CONF["hostname"], "service": CONF["name"], "zone_id": zone, "environment": "production"}).encode())
print("address:", CONF["hostname"], "ok" if r.get("success") else r.get("errors"))
print("hook address for Supabase: https://%s/hook/send-email" % CONF["hostname"])
