#!/usr/bin/env python3
"""Push deb files to wacljcr/mumu repo via GitHub Contents API.

源结构（wacljcr/mumu）:
  - debs/          存放所有 deb 文件（根目录，不是 debian/pool/main）
  - gen_packages.py 扫描 debs/ 生成根目录 Packages / Packages.bz2 / Packages.gz / Release
  - Packages/Release 都在仓库根目录

本脚本只负责把新编译的 deb 放进 debs/，然后触发 gen_packages.py 重新生成索引。
索引文件通过 GitHub Actions workflow 本地生成后推送。
"""
import base64
import json
import os
import sys
import urllib.request
import urllib.error

REPO = "wacljcr/mumu"
BRANCH = "main"
TOKEN = os.environ.get("GH_TOKEN", "")


def api_get(path):
    """GET a file's metadata (returns dict or None)."""
    url = f"https://api.github.com/repos/{REPO}/contents/{path}?ref={BRANCH}"
    headers = {
        "Authorization": f"token {TOKEN}",
        "Accept": "application/vnd.github+json",
    }
    try:
        req = urllib.request.Request(url, headers=headers)
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.loads(resp.read())
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return None
        raise


def push_file(path, content_bytes, message=None):
    """Create or update a file via Contents API."""
    headers = {
        "Authorization": f"token {TOKEN}",
        "Accept": "application/vnd.github+json",
        "Content-Type": "application/json",
    }
    b64 = base64.b64encode(content_bytes).decode()

    existing = api_get(path)
    sha = existing.get("sha") if existing else None

    payload = {"message": message or f"Auto-update {path}", "content": b64}
    if sha:
        payload["sha"] = sha

    url = f"https://api.github.com/repos/{REPO}/contents/{path}"
    data = json.dumps(payload).encode()
    req = urllib.request.Request(url, data=data, headers=headers, method="PUT")
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            print(f"Pushed: {path} (HTTP {resp.status})")
    except urllib.error.HTTPError as e:
        body = e.read().decode()[:500]
        print(f"FAILED: {path} (HTTP {e.code}): {body}")
        sys.exit(1)


def main():
    # 1. 把新编译的 deb 上传到 debs/（源的实际 pool 目录）
    deb_dir = "debs"
    if os.path.isdir(deb_dir):
        for f in sorted(os.listdir(deb_dir)):
            if f.endswith(".deb"):
                with open(os.path.join(deb_dir, f), "rb") as fh:
                    push_file(f"debs/{f}", fh.read(), f"Auto-build: {f}")

    # 2. 索引文件由 workflow 本地生成后放在 debian/... 和根目录
    #    实际源使用根目录 Packages/Release，所以优先推根目录版本
    index_files = [
        "Packages",
        "Packages.bz2",
        "Release",
    ]
    for fname in index_files:
        if os.path.exists(fname):
            with open(fname, "rb") as fh:
                push_file(fname, fh.read(), f"Auto-update index: {fname}")

    print("All done!")


if __name__ == "__main__":
    main()
