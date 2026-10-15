#!/usr/bin/env python3
"""Push deb files to wacljcr/mumu repo via GitHub Contents API."""
import base64
import json
import os
import sys
import urllib.request
import urllib.error

REPO = "wacljcr/mumu"
BRANCH = "main"
TOKEN = os.environ.get("GH_TOKEN", "")


def push_file(path, content_file):
    url = f"https://api.github.com/repos/{REPO}/contents/{path}?ref={BRANCH}"
    headers = {
        "Authorization": f"token {TOKEN}",
        "Accept": "application/vnd.github+json",
        "Content-Type": "application/json",
    }

    with open(content_file, "rb") as f:
        b64 = base64.b64encode(f.read()).decode()

    # Check if file exists (get SHA for update)
    sha = None
    try:
        req = urllib.request.Request(url, headers=headers)
        with urllib.request.urlopen(req) as resp:
            data = json.loads(resp.read())
            sha = data.get("sha")
    except urllib.error.HTTPError as e:
        if e.code != 404:
            print(f"Warning checking {path}: {e.code}")

    payload = {"message": f"Auto-update {path}", "content": b64}
    if sha:
        payload["sha"] = sha

    put_url = f"https://api.github.com/repos/{REPO}/contents/{path}"
    data = json.dumps(payload).encode()
    req = urllib.request.Request(put_url, data=data, headers=headers, method="PUT")
    try:
        with urllib.request.urlopen(req) as resp:
            print(f"Pushed: {path} (HTTP {resp.status})")
    except urllib.error.HTTPError as e:
        body = e.read().decode()[:500]
        print(f"FAILED: {path} (HTTP {e.code}): {body}")
        sys.exit(1)


def main():
    files_to_push = []

    # Deb files
    deb_dir = "debian/pool/main"
    if os.path.isdir(deb_dir):
        for f in sorted(os.listdir(deb_dir)):
            if f.endswith(".deb"):
                files_to_push.append((f"debian/pool/main/{f}", os.path.join(deb_dir, f)))

    # Packages and Packages.bz2
    for fname in ["Packages", "Packages.bz2"]:
        fpath = f"debian/dists/stable/main/binary-all/{fname}"
        if os.path.exists(fpath):
            files_to_push.append((fpath, fpath))

    # Release
    if os.path.exists("Release"):
        files_to_push.append(("Release", "Release"))

    print(f"Files to push: {len(files_to_push)}")
    for path, _ in files_to_push:
        print(f"  - {path}")

    for path, fpath in files_to_push:
        push_file(path, fpath)

    print("All done!")


if __name__ == "__main__":
    main()
