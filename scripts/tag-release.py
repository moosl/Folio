#!/usr/bin/env python3
"""Local, tag-driven release publisher. Invoked by the user's LaunchAgent."""
import base64
import fcntl
import hashlib
import json
import logging
from logging.handlers import RotatingFileHandler
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

REPO = "moosl/Folio"
REMOTE = f"https://github.com/{REPO}.git"
ROOT = Path.home() / "Library/Application Support/FolioRelease"
MIRROR = ROOT / "source.git"
SEMVER = re.compile(r"v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)")
SP = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
LOG = logging.getLogger("folio.release")


def run(*args, cwd=None, env=None):
    return subprocess.check_output(args, cwd=cwd, env=env, text=True).strip()


def api(route):
    return json.loads(run("gh", "api", f"repos/{REPO}/{route}"))


def version(tag):
    match = SEMVER.fullmatch(tag)
    return tuple(map(int, match.groups())) if match else None


def verify_signature(key, file, signature, tmp):
    # DER SubjectPublicKeyInfo for Ed25519 (RFC 8410), with the public key embedded in Folio.
    raw = base64.b64decode(key, validate=True)
    sig = base64.b64decode(signature, validate=True)
    if len(raw) != 32 or len(sig) != 64:
        raise ValueError("Unexpected Ed25519 key or signature length")
    pub, detached = tmp / "pub.der", tmp / "signature"
    pub.write_bytes(bytes.fromhex("302a300506032b6570032100") + raw)
    detached.write_bytes(sig)
    run("openssl", "pkeyutl", "-verify", "-pubin", "-keyform", "DER", "-inkey", pub,
        "-rawin", "-in", file, "-sigfile", detached)


def read_feed(file, key, tag, archive=None):
    data = file.read_bytes()
    footer = re.search(rb"<!-- sparkle-signatures:\s*edSignature: (\S+)\s*length: (\d+)\s*-->\s*\Z", data)
    if not footer or int(footer[2]) != footer.start():
        raise ValueError("Unexpected signed appcast footer")
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        payload = tmp / "payload"
        payload.write_bytes(data[:footer.start()])
        verify_signature(key, payload, footer[1], tmp)
        item = ET.fromstring(data).find("./channel/item")
        if item is None or item.findtext(SP + "shortVersionString") != tag[1:]:
            raise ValueError("Appcast version does not match release")
        enclosure = item.find("enclosure")
        name = f"Folio-{tag[1:]}-macOS-arm64.zip"
        if enclosure is None or enclosure.get("url") != f"https://github.com/{REPO}/releases/download/{tag}/{name}":
            raise ValueError("Unexpected update download URL")
        if archive:
            if archive.stat().st_size != int(enclosure.attrib["length"]):
                raise ValueError("Update archive size mismatch")
            verify_signature(key, archive, enclosure.attrib[SP + "edSignature"], tmp)
        build = int(item.findtext(SP + "version"))
        if build < 1:
            raise ValueError("Invalid build number")
        return build


def latest():
    release = api("releases/latest")
    if version(release["tag_name"]) is None or release["draft"] or release["prerelease"]:
        raise ValueError("Expected a stable Latest release")
    return release["tag_name"]


def publish(tag, sha, previous):
    job = ROOT / "jobs" / tag
    job.mkdir(parents=True, exist_ok=True)
    key = run("git", "-C", MIRROR, "show", f"{sha}:app/Info.plist")
    import plistlib
    key = plistlib.loads(key.encode())["SUPublicEDKey"]
    run("gh", "release", "download", previous, "--repo", REPO, "--pattern", "appcast.xml",
        "--output", job / "previous.xml", "--clobber")
    build = read_feed(job / "previous.xml", key, previous) + 1
    record = job / "source.json"
    expected = {"commit": sha, "build": build}
    if record.exists() and json.loads(record.read_text()) != expected:
        raise ValueError(f"{tag} changed after packaging began; investigate before retrying")
    record.write_text(json.dumps(expected))
    name = f"Folio-{tag[1:]}-macOS-arm64.zip"
    archive, feed = job / name, job / "appcast.xml"
    if not (archive.exists() and feed.exists()):
        LOG.info("Building %s (%s) at %s", tag, build, sha)
        with tempfile.TemporaryDirectory(dir=ROOT, prefix="build-") as td:
            work = Path(td)
            run("git", "clone", "--quiet", "--no-checkout", str(MIRROR), str(work))
            run("git", "checkout", "--quiet", "--detach", sha, cwd=work)
            (work / ".build").mkdir()
            (work / ".build/vendor").symlink_to(ROOT / "vendor", target_is_directory=True)
            env = dict(os.environ, FOLIO_RELEASE_VERSION=tag[1:], FOLIO_RELEASE_BUILD=str(build))
            with (job / "build.log").open("a") as out:
                subprocess.run(["bash", "scripts/release.sh"], cwd=work, env=env, stdout=out,
                               stderr=subprocess.STDOUT, check=True)
            if read_feed(work / "dist/appcast.xml", key, tag, work / "dist" / name) != build:
                raise ValueError("Signed build number mismatch")
            for src, dest in [(work / "dist" / name, archive), (work / "dist/appcast.xml", feed)]:
                shutil.copyfile(src, dest.with_suffix(".partial"))
                dest.with_suffix(".partial").replace(dest)
    if read_feed(feed, key, tag, archive) != build:
        raise ValueError("Cached signed build mismatch")
    assets = {p.name: "sha256:" + hashlib.sha256(p.read_bytes()).hexdigest() for p in (archive, feed)}
    marker = f"<!-- folio-tag-release {sha} -->"
    releases = json.loads(run("gh", "api", "--paginate", "--slurp", f"repos/{REPO}/releases?per_page=100"))
    draft = next((r for page in releases for r in page if r["tag_name"] == tag), None)
    if draft and (not draft["draft"] or marker not in (draft["body"] or "")):
        raise ValueError("Existing release is not this publisher's draft")
    if not draft:
        notes = job / "notes.md"
        notes.write_text(f"适用于 Apple Silicon，macOS 13 或更高版本。\n\n"
                         f"[查看 {previous} 至 {tag} 的变更](https://github.com/{REPO}/compare/{previous}...{tag})\n\n{marker}\n")
        run("gh", "release", "create", tag, "--repo", REPO, "--verify-tag", "--draft",
            "--title", f"Folio {tag[1:]}", "--notes-file", notes)
    run("gh", "release", "upload", tag, str(archive), str(feed), "--repo", REPO, "--clobber")
    remote = json.loads(run("gh", "release", "view", tag, "--repo", REPO, "--json", "assets"))["assets"]
    if {a["name"]: a["digest"] for a in remote} != assets:
        raise ValueError("Remote draft asset digests do not match signed local files")
    # Recheck both moving refs before changing the public update channel.
    refresh()
    if commit(tag) != sha or not on_main(sha) or latest() != previous:
        raise ValueError("Tag or Latest changed during packaging; draft retained")
    run("gh", "release", "edit", tag, "--repo", REPO, "--draft=false", "--latest")
    LOG.info("Published https://github.com/%s/releases/tag/%s", REPO, tag)


def refresh():
    run("git", "-C", MIRROR, "fetch", "--quiet", "--no-tags", "--prune", REMOTE,
        "+refs/heads/main:refs/heads/main", "+refs/tags/v*:refs/tags/v*")


def commit(tag):
    return run("git", "-C", MIRROR, "rev-parse", f"refs/tags/{tag}^{{commit}}")


def on_main(sha):
    result = subprocess.run(["git", "-C", MIRROR, "merge-base", "--is-ancestor", sha, "refs/heads/main"])
    if result.returncode not in (0, 1):
        result.check_returncode()
    return result.returncode == 0


def main():
    os.umask(0o077)
    ROOT.mkdir(parents=True, exist_ok=True)
    LOG.setLevel(logging.INFO)
    LOG.addHandler(RotatingFileHandler(ROOT / "publisher.log", maxBytes=1000000, backupCount=2))
    LOG.handlers[0].setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(message)s"))
    with (ROOT / "run.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return
        (ROOT / "vendor").mkdir(exist_ok=True)
        if not MIRROR.exists():
            run("git", "init", "--bare", "--quiet", str(MIRROR))
        refresh()
        previous = latest()
        tags = run("git", "-C", MIRROR, "tag", "--list", "v*").splitlines()
        for tag in sorted((t for t in tags if version(t) and version(t) > version(previous)), key=version):
            sha = commit(tag)
            if on_main(sha):
                publish(tag, sha, previous)
                previous = tag


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        LOG.error("%s", error)
        sys.exit(1)
