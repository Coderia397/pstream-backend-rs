#!/usr/bin/env python3
"""Adds streams.watch to Resend (if missing), publishes the DNS records Resend asks for in Cloudflare, and asks Resend to verify.
Safe to repeat. Reads ~/.config/streams/cloudflare.env and resend_admin.env (the full access key; the Worker only gets a sending key); prints no secrets."""
import json, pathlib, sys, time, urllib.request, urllib.error

CFG = pathlib.Path.home() / ".config/streams"
def load(name):
    return dict(l.split("=", 1) for l in (CFG / name).read_text().splitlines() if "=" in l and not l.startswith("#"))
cf, rs = load("cloudflare.env"), {"RESEND_API_KEY": load("resend_admin.env")["RESEND_ADMIN_KEY"]}
DOMAIN = "streams.watch"

def call(base, method, path, headers, data=None):
    req = urllib.request.Request(base + path, method=method, data=None if data is None else json.dumps(data).encode(), headers={**headers, "Content-Type": "application/json", "User-Agent": "curl/8.7.1"})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        return json.loads(e.read() or b"{}")
resend = lambda m, p, d=None: call("https://api.resend.com", m, p, {"Authorization": "Bearer " + rs["RESEND_API_KEY"]}, d)
cloud = lambda m, p, d=None: call("https://api.cloudflare.com/client/v4", m, p, {"X-Auth-Email": cf["CF_EMAIL"], "X-Auth-Key": cf["CF_KEY"]}, d)

domains = resend("GET", "/domains").get("data", [])
found = next((d for d in domains if d["name"] == DOMAIN), None)
if not found:
    found = resend("POST", "/domains", {"name": DOMAIN})
domain = resend("GET", "/domains/" + found["id"])
existing = cloud("GET", f"/zones/{cf['CF_ZONE']}/dns_records?per_page=200").get("result", [])
for rec in domain["records"]:
    full = f"{rec['name']}.{DOMAIN}"
    value = rec["value"]
    body = {"type": rec["type"], "name": full, "content": value, "ttl": 1, "proxied": False}
    if rec["type"] == "MX":
        body["priority"] = rec["priority"]
    if rec["type"] == "TXT":
        body["content"] = value
    same = [e for e in existing if e["type"] == rec["type"] and e["name"] == full]
    if any(e["content"].strip('"') == value for e in same):
        print("already there:", rec["type"], full); continue
    r = cloud("POST", f"/zones/{cf['CF_ZONE']}/dns_records", body)
    print("added:" if r.get("success") else "FAILED:", rec["type"], full, "" if r.get("success") else r.get("errors"))
print("verify:", resend("POST", f"/domains/{found['id']}/verify").get("object", "requested"))
for _ in range(12):
    time.sleep(10)
    status = resend("GET", "/domains/" + found["id"])
    print("status:", status.get("status"), [r["status"] for r in status["records"]])
    if status.get("status") in ("verified", "failed"):
        break
