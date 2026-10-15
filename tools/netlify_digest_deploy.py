#!/usr/bin/env python3
"""Netlify file-digest deploy (for sites too large for the one-shot zip endpoint).

Flow (Netlify API): POST /sites/{id}/deploys with {files: {path: sha1}} ->
server returns `required` digests it does not already have -> PUT each
required file to /deploys/{deploy_id}/files/{path} -> poll until ready.
Unchanged files are reused server-side, so a deploy that only adds one APK
uploads just that APK. Auth via the stored custom.netlify connector.
"""
import argparse
import hashlib
import json
import os
import sys
import time
import urllib.request

sys.path.insert(0, "/opt/hatch/skills/skill-creator/bin")
from dynamic_credentials import add_surrogate_to_request, read_json_response

API = "https://api.netlify.com/api/v1"
CRED = "custom.netlify"


def _req(method, url, data=None, content_type=None):
    req = urllib.request.Request(url, data=data, method=method)
    if content_type:
        req.add_header("Content-Type", content_type)
    add_surrogate_to_request(req, CRED, allowed_hosts=["api.netlify.com"])
    return req


def _sha1(path):
    h = hashlib.sha1()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--site-id", required=True)
    ap.add_argument("--dir", required=True)
    ap.add_argument("--title", default="deploy")
    args = ap.parse_args()

    files, by_digest = {}, {}
    for root, _, names in os.walk(args.dir):
        for fn in names:
            full = os.path.join(root, fn)
            rel = os.path.relpath(full, args.dir).replace(os.sep, "/")
            digest = _sha1(full)
            files[rel] = digest
            by_digest[digest] = (rel, full)
    print(f"{len(files)} files, {sum(os.path.getsize(p) for _, p in by_digest.values()) / 1e6:.1f} MB total")

    body = json.dumps({"files": files, "title": args.title}).encode()
    with urllib.request.urlopen(_req("POST", f"{API}/sites/{args.site_id}/deploys", body, "application/json"), timeout=60) as resp:
        dep = read_json_response(resp)
    deploy_id = dep["id"]
    required = dep.get("required", [])
    print(f"deploy {deploy_id}: server needs {len(required)} of {len(files)} files")

    for digest in required:
        rel, full = by_digest[digest]
        with open(full, "rb") as f:
            data = f.read()
        url = f"{API}/deploys/{deploy_id}/files/{urllib.parse.quote(rel, safe='')}"
        with urllib.request.urlopen(_req("PUT", url, data, "application/octet-stream"), timeout=300) as resp:
            resp.read()
        print(f"uploaded {rel} ({len(data) / 1e6:.1f} MB)")

    deadline = time.time() + 600
    while time.time() < deadline:
        with urllib.request.urlopen(_req("GET", f"{API}/deploys/{deploy_id}", None, None), timeout=30) as resp:
            cur = read_json_response(resp)
        state = cur.get("state")
        print(f"deploy state: {state}")
        if state == "ready":
            print(json.dumps({"deploy_id": deploy_id, "state": state,
                              "url": cur.get("ssl_url") or cur.get("deploy_ssl_url")}, indent=2))
            return 0
        if state in ("error",):
            print(f"deploy failed: {cur.get('error_message')}", file=sys.stderr)
            return 1
        time.sleep(15)
    print("timed out waiting for deploy to become ready", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
