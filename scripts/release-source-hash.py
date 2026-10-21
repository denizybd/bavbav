#!/usr/bin/env python3
"""Fingerprint public Git inputs and ignored private build inputs, without secrets."""
import hashlib
import json
import os
import pathlib
import plistlib
import subprocess
import sys
import time


def source_hash(root):
    root = pathlib.Path(root).resolve()
    workspace_mode = os.environ.get("BAVBAV_WITH_WORKSPACE", "auto")
    if workspace_mode not in ("auto", "0", "1"):
        raise RuntimeError("BAVBAV_WITH_WORKSPACE must be auto, 0, or 1.")
    workspace_enabled = workspace_mode == "1" or (
        workspace_mode == "auto" and (root / "Sources/IkiWorkspaceKit").is_dir()
    )
    names = subprocess.check_output(
        ["/usr/bin/git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"], cwd=root
    ).decode("utf-8").split("\0")
    # These ignored directories affect the executable but must never be added
    # to the public repository. Include their bytes only in the build receipt.
    for directory in ("Sources/IkiWorkspaceKit", "Vendor/IkiWorkspace/Resources"):
        base = root / directory
        if base.exists():
            names.extend(str(p.relative_to(root)) for p in base.rglob("*") if not p.is_dir())
    digest = hashlib.sha256()
    # The same checkout may intentionally produce public/private app flavors.
    # Bind the receipt to the actual compiler boundary, not just source bytes.
    digest.update(b"workspace-enabled\0" + (b"1" if workspace_enabled else b"0") + b"\0")
    for name in sorted(set(filter(None, names))):
        if name == "Vendor/IkiWorkspace/Resources/app-version.json":
            continue  # Derived from this fingerprint, never a hash input itself.
        path = root / name
        if not path.exists() and not path.is_symlink():
            continue
        digest.update(name.encode("utf-8") + b"\0")
        if path.is_symlink():
            digest.update(b"link\0" + os.readlink(path).encode("utf-8"))
        elif path.is_file():
            digest.update(b"executable\0" if path.stat().st_mode & 0o111 else b"file\0")
            with path.open("rb") as stream:
                for block in iter(lambda: stream.read(1024 * 1024), b""):
                    digest.update(block)
        else:
            raise RuntimeError("Unsupported source input: " + name)
        digest.update(b"\0")
    return digest.hexdigest()


def notify_publisher(root, receipt):
    control = pathlib.Path.home() / "Library/Application Support/Bavbav Release Automation/publisher"
    config = control / "config.json"
    if not config.exists():
        return
    settings = json.loads(config.read_text())
    if pathlib.Path(settings["host"]).resolve() != root.resolve():
        raise RuntimeError("Release automation belongs to a different checkout.")
    with (control / "task.log").open("ab") as output, (control / "task-error.log").open("ab") as errors:
        process = subprocess.Popen([str(control / "runtime/node"), settings["script"], "--config", str(config), "--watch"], stdin=subprocess.DEVNULL, stdout=output, stderr=errors, start_new_session=True, env={**os.environ, "NODE_OPTIONS": ""})
    (control / "publisher-trigger.json").write_text(json.dumps({"pid": process.pid, "receipt": str(receipt), "triggeredAt": time.time()}))


if __name__ == "__main__":
    root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else pathlib.Path(__file__).resolve().parent.parent)
    if "--notify" in sys.argv[2:]:
        notify_publisher(root, sys.argv[sys.argv.index("--notify") + 1])
        raise SystemExit(0)
    digest = source_hash(root)
    if "--prepare" in sys.argv[2:]:
        path = root / "Vendor/IkiWorkspace/Resources/app-version.json"
        # Public builds have no private runtime manifest to stamp. The build
        # script independently rejects a requested-but-incomplete private build.
        if os.environ.get("BAVBAV_WITH_WORKSPACE") != "0" and path.is_file():
            manifest = json.loads(path.read_text())
            info = plistlib.loads((root / "AppResources/Info.plist").read_bytes())
            manifest.update(version=info["CFBundleShortVersionString"], build=int(info["CFBundleVersion"]), commit=digest, sourceHash=digest, builtBy="deniz")
            path.write_text(json.dumps(manifest, indent=2) + "\n")
    print(digest)
