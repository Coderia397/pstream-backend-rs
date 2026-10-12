#!/usr/bin/env python3
"""Writes bundles/<lang>.json from the shared translation files: every `email-*` message of i18n/<lang>.ftl in the frontend
repository. English is the full set; another language holds what has been translated so far and the rest is read from English
when an email is written. Run it after the translations change, then rebuild the Worker."""
import json, pathlib, sys
HERE = pathlib.Path(__file__).resolve().parent
I18N = HERE.parent.parent / "streams-frontend-rs" / "i18n"
sys.path.insert(0, str(HERE.parent.parent / "streams-frontend-rs" / "scripts" / "i18n"))
import ftl
LANGS = ["en", "ar", "de", "es", "fr", "hi", "it", "ja", "ko", "nl", "pl", "pt", "ru", "sv", "tr", "zh"]
(HERE / "bundles").mkdir(exist_ok=True)
for lang in LANGS:
    f = I18N / f"{lang}.ftl"
    entries = ftl.read(f.read_text()) if f.exists() else []
    bundle = {k: v for k, v in entries if k.startswith("email-")}
    (HERE / "bundles" / f"{lang}.json").write_text(json.dumps(bundle, ensure_ascii=False, indent=0) + "\n")
    print(f"{lang}: {len(bundle)} email messages")
