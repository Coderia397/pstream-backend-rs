#!/usr/bin/env python3
"""Sets up sending from the Streams domain with Brevo: asks Brevo for the domain's DNS records, adds any that are missing in
Cloudflare (CNAME records DNS only), asks Brevo to authenticate the domain, and creates the sender address. Safe to repeat.
Reads private credential files from ~/.config/streams: brevo.env (BREVO_API_KEY) and cloudflare.env (CF_EMAIL, CF_KEY, CF_ZONE).
  python3 setup_email_dns.py [--sender no-reply@streams.watch] [--name Streams]"""
import json, pathlib, sys, urllib.request, urllib.error

DOMAIN = "streams.watch"
args = sys.argv[1:]
sender = args[args.index("--sender") + 1] if "--sender" in args else f"no-reply@{DOMAIN}"
name = args[args.index("--name") + 1] if "--name" in args else "Streams"

def load(file):
    p = pathlib.Path.home() / ".config/streams" / file
    return dict(l.split("=", 1) for l in p.read_text().splitlines() if "=" in l and not l.startswith("#"))
brevo, cf = load("brevo.env"), load("cloudflare.env")

def http(url, method, headers, body=None):
    req = urllib.request.Request(url, method=method, data=json.dumps(body).encode() if body is not None else None, headers={"Content-Type": "application/json", "User-Agent": "curl/8.7.1", **headers})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return r.status, json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        try: return e.code, json.loads(e.read() or b"{}")
        except Exception: return e.code, {}
def b(method, path, body=None): return http("https://api.brevo.com/v3" + path, method, {"api-key": brevo["BREVO_API_KEY"], "accept": "application/json"}, body)
def c(method, path, body=None): return http("https://api.cloudflare.com/client/v4" + path, method, {"X-Auth-Email": cf["CF_EMAIL"], "X-Auth-Key": cf["CF_KEY"]}, body)

# 1. the records Brevo wants (adding the domain again returns them)
st, d = b("GET", "/senders/domains")
domain = next((x for x in d.get("domains", []) if x.get("domain_name") == DOMAIN), None)
if not domain:
    st, domain = b("POST", "/senders/domains", {"name": DOMAIN})
    if st != 200: sys.exit(f"could not add the domain: {st} {domain}")
rec = b("GET", f"/senders/domains/{DOMAIN}")[1].get("dns_records", {})
wanted = [(r["type"], DOMAIN if r["host_name"] == "@" else f'{r["host_name"]}.{DOMAIN}', r["value"]) for r in rec.values() if isinstance(r, dict) and r.get("type")]

# 2. add what is missing in Cloudflare
zone = cf["CF_ZONE"]
st, existing = c("GET", f"/zones/{zone}/dns_records?per_page=500")
have = {(r["type"], r["name"], r["content"].strip('"')) for r in existing.get("result", [])}
for typ, host, value in wanted:
    if (typ, host, value) in have:
        print("already there:", typ, host); continue
    st, r = c("POST", f"/zones/{zone}/dns_records", {"type": typ, "name": host, "content": value, "ttl": 1, "proxied": False})
    print("added:" if r.get("success") else f"FAILED {r.get('errors')}:", typ, host)

# 3. ask Brevo to check the records, then make sure the sender exists
st, r = b("PUT", f"/senders/domains/{DOMAIN}/authenticate")
print("authenticate:", st, r.get("message") or r)
st, s = b("GET", "/senders")
if not any(x.get("email") == sender for x in s.get("senders", [])):
    st, r = b("POST", "/senders", {"name": name, "email": sender})
    print("sender:", st, r.get("id") or r)
else:
    print("sender already exists:", sender)
st, d = b("GET", f"/senders/domains/{DOMAIN}")
print("domain authenticated:", d.get("authenticated"), "| records:", {k: v.get("status") for k, v in (d.get("dns_records") or {}).items() if isinstance(v, dict)})
