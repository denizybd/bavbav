#!/usr/bin/env python3
"""Pinned, repository-owned Ollama provisioning. Python standard library only.

No global Ollama daemon is started, stopped, configured, or used for inference.
All stdout is a single JSON result; progress diagnostics go to stderr.
"""
import argparse
import base64
import ctypes
import fcntl
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import signal
import socket
import stat
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from unittest import mock

MODEL = "huihui_ai/qwen3-abliterated:14b-v2"
HOST = "127.0.0.1"
PORT = 11439
ENDPOINT = "http://127.0.0.1:11439"
HEX = re.compile(r"^[a-f0-9]{64}$")
MAX_JSON = 4 * 1024 * 1024


class Failure(Exception):
    pass


def diagnostic(message):
    print(message, file=sys.stderr, flush=True)


def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as source:
        while True:
            data = source.read(8 * 1024 * 1024)
            if not data:
                break
            digest.update(data)
    return digest.hexdigest()


def no_symlinks(path):
    path = Path(os.path.abspath(path))
    for part in [path, *path.parents]:
        if part.is_symlink():
            raise Failure("Symlink path is not allowed: " + str(part))
    return path


def private_directory(path):
    path = no_symlinks(path)
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    info = path.stat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid():
        raise Failure("Runtime directory must belong to the current user: " + str(path))
    if info.st_mode & 0o077:
        raise Failure("Runtime directory must be private (mode 0700): " + str(path))
    return path


def safe_file(path, private=True):
    path = no_symlinks(path)
    if path.exists():
        info = path.stat()
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid():
            raise Failure("Unsafe runtime file: " + str(path))
        if private and info.st_mode & 0o022:
            raise Failure("Writable-by-other-users runtime file: " + str(path))
    return path


def read_json(path):
    if path.stat().st_size > MAX_JSON:
        raise Failure("JSON record is too large: " + str(path))
    return json.loads(path.read_text())


def atomic_bytes(path, data, mode=0o600):
    path = safe_file(path)
    private_directory(path.parent)
    fd, temporary = tempfile.mkstemp(prefix=".install-", dir=path.parent)
    try:
        os.fchmod(fd, mode)
        with os.fdopen(fd, "wb") as destination:
            destination.write(data)
            destination.flush()
            os.fsync(destination.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def atomic_json(path, value):
    atomic_bytes(path, (json.dumps(value, indent=2) + "\n").encode())


def validate_relative(value):
    path = Path(value)
    if path.is_absolute() or not path.parts or any(p in (".", "..") for p in path.parts):
        raise Failure("Unsafe manifest relative path")
    return path


class Installer:
    def __init__(self, repo):
        self.repo = no_symlinks(repo)
        self.lock_path = safe_file(self.repo / "Resources/LocalAI/model-lock.json", private=False)
        self.lock = read_json(self.lock_path)
        self.model = self.lock["model"]
        self.runtime = self.lock["runtime"]
        if self.model["id"] != MODEL or self.lock.get("schemaVersion") != 1:
            raise Failure("Unknown local model lock; no model substitution is permitted")
        self.manifest = base64.b64decode(self.model["manifestBase64"], validate=True)
        if hashlib.sha256(self.manifest).hexdigest() != self.model["manifestSHA256"]:
            raise Failure("Pinned manifest bytes do not match their SHA256")
        parsed = json.loads(self.manifest)
        self.layers = [parsed["config"], *parsed["layers"]]
        for layer in self.layers:
            if not layer["digest"].startswith("sha256:") or not HEX.fullmatch(layer["digest"][7:]):
                raise Failure("Invalid layer SHA256")
            if not isinstance(layer["size"], int) or layer["size"] <= 0:
                raise Failure("Invalid layer size")
        self.root = no_symlinks(self.repo / "Runtime/LocalAI")
        self.resources = self.root / "runtime"
        self.models = self.root / "models"
        self.binary = self.resources / "ollama"
        self.receipt = self.root / "installation.json"
        self.process_state = self.root / "server.json"
        self.operation_lock = None

    def lock_operation(self):
        private_directory(self.repo / "Runtime")
        private_directory(self.root)
        path = safe_file(self.root / "operation.lock")
        self.operation_lock = open(path, "a+")
        os.chmod(path, 0o600)
        try:
            fcntl.flock(self.operation_lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise Failure("Another local-AI setup or lifecycle operation is already running")

    def expected_files(self):
        result = []
        for item in self.runtime["files"]:
            rel = validate_relative(item["path"])
            if "link" not in item:
                result.append((self.resources / rel, item["sha256"], item["size"]))
        for layer in self.layers:
            result.append((self.models / "blobs" / layer["digest"].replace(":", "-"),
                           layer["digest"][7:], layer["size"]))
        return result

    def model_manifest_path(self, folder=None):
        return (folder or self.models) / "manifests/registry.ollama.ai/huihui_ai/qwen3-abliterated/14b-v2"

    def validate_runtime_links(self):
        pinned = {str(validate_relative(item["path"])): item for item in self.runtime["files"]}
        for item in self.runtime["files"]:
            if "link" not in item:
                continue
            path = self.resources / validate_relative(item["path"])
            seen = set()
            # Ollama ships alias chains, e.g. dylib -> .0.dylib -> .0.27.0.dylib.
            # Follow only explicitly pinned same-directory links, never a raw
            # resolve() through arbitrary files or an escaping target.
            while True:
                relative = str(path.relative_to(self.resources))
                expected = pinned.get(relative)
                if expected is None or relative in seen:
                    raise Failure("Runtime library alias points outside the pinned file graph")
                seen.add(relative)
                if "link" not in expected:
                    safe_file(path)
                    if not path.is_file():
                        raise Failure("Runtime library alias has no regular-file target")
                    break
                link = validate_relative(expected["link"])
                if len(link.parts) != 1 or not path.is_symlink() or os.readlink(path) != expected["link"]:
                    raise Failure("Runtime library alias is missing or changed: " + str(path))
                path = path.parent / link

    def verified(self, full=False):
        try:
            safe_file(self.receipt)
            record = read_json(self.receipt)
            if record.get("model") != MODEL or record.get("lockSHA256") != sha256(self.lock_path):
                return False, "Installation receipt does not match the pinned model lock"
            stamps = record["files"]
            for path, digest, size in self.expected_files():
                safe_file(path)
                info = path.stat()
                stamp = stamps.get(str(path.relative_to(self.root)), {})
                if info.st_size != size:
                    return False, "An installed asset has a different size"
                if full or stamp.get("mtimeNS") != info.st_mtime_ns or stamp.get("size") != size:
                    if sha256(path) != digest:
                        return False, "An installed asset failed SHA256 verification"
                if info.st_nlink != 1:
                    return False, "Hard-linked installed assets are not permitted"
            self.validate_runtime_links()
            manifest = safe_file(self.model_manifest_path())
            if sha256(manifest) != self.model["manifestSHA256"]:
                return False, "Installed model manifest does not match"
            return True, "All pinned assets are installed"
        except (OSError, KeyError, ValueError, Failure) as error:
            return False, str(error)

    def write_receipt(self, source):
        files = {}
        for path, digest, size in self.expected_files():
            info = path.stat()
            files[str(path.relative_to(self.root))] = {"sha256": digest, "size": size,
                                                      "mtimeNS": info.st_mtime_ns}
        record = {"schemaVersion": 1, "model": MODEL, "apiDigest": self.model["apiDigest"],
                  "runtimeVersion": self.runtime["version"], "installedAt": time.time(),
                  "lockSHA256": sha256(self.lock_path), "source": source, "files": files}
        atomic_json(self.receipt, record)

    def clone_verified(self, source, destination, digest, size, executable=False):
        safe_file(source, private=False)
        if source.is_symlink() or source.stat().st_size != size or sha256(source) != digest:
            raise Failure("Source asset does not match pinned SHA256: " + str(source))
        safe_file(destination)
        if destination.exists() and destination.stat().st_size == size and sha256(destination) == digest:
            return
        private_directory(destination.parent)
        fd, temporary = tempfile.mkstemp(prefix=".clone-", dir=destination.parent)
        os.close(fd)
        try:
            if platform.system() == "Darwin":
                copied = subprocess.run(["/bin/cp", "-c", str(source), temporary],
                                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0
            else:
                copied = False
            if not copied:
                if shutil.disk_usage(destination.parent).free < size + 64 * 1024 * 1024:
                    raise Failure("Not enough disk space to copy the local model")
                shutil.copyfile(source, temporary)
            os.chmod(temporary, 0o700 if executable else 0o600)
            if os.stat(temporary).st_nlink != 1 or sha256(temporary) != digest:
                raise Failure("Cloned asset failed SHA256 or hard-link verification")
            os.replace(temporary, destination)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)

    def local_runtime(self):
        candidates = [Path.home() / ".local/bin/ollama", Path("/Applications/Ollama.app/Contents/Resources/ollama")]
        expected = next(i for i in self.runtime["files"] if i["path"] == "ollama")
        for candidate in candidates:
            try:
                source = candidate.resolve(strict=True)
                if source.is_file() and source.stat().st_size == expected["size"] and sha256(source) == expected["sha256"]:
                    return source.parent
            except OSError:
                continue
        return None

    def provision_runtime(self, allow_download):
        source = self.local_runtime()
        temporary = None
        if source is None:
            if not allow_download:
                raise Failure("Pinned Ollama runtime is unavailable locally; explicit --allow-download is required")
            archive = self.root / "downloads/ollama-darwin.tgz"
            self.download(self.runtime["archiveURL"], archive, self.runtime["archiveSHA256"], self.runtime["archiveBytes"])
            temporary = tempfile.TemporaryDirectory(prefix=".runtime-", dir=self.root)
            extracted = Path(temporary.name)
            with tarfile.open(archive, "r:gz") as package:
                for entry in package.getmembers():
                    validate_relative(entry.name)
                    if entry.islnk() or entry.issym():
                        # Recreate only explicitly pinned library aliases below.
                        continue
                    if not entry.isfile() and not entry.isdir():
                        raise Failure("Unsupported runtime archive member")
                    target = extracted / entry.name
                    if entry.isdir():
                        private_directory(target)
                    else:
                        private_directory(target.parent)
                        data = package.extractfile(entry)
                        if data is None:
                            raise Failure("Cannot read runtime archive member")
                        with open(target, "xb") as output:
                            shutil.copyfileobj(data, output)
                        os.chmod(target, 0o700 if entry.mode & 0o100 else 0o600)
            expected = next(i for i in self.runtime["files"] if i["path"] == "ollama")
            candidates = [f.parent for f in extracted.rglob("ollama") if f.is_file() and sha256(f) == expected["sha256"]]
            if len(candidates) != 1:
                raise Failure("Official runtime archive does not contain the pinned executable")
            source = candidates[0]
        diagnostic("Provisioning pinned Ollama 0.40.6 into repository-owned Runtime/LocalAI/runtime")
        try:
            private_directory(self.resources)
            for item in self.runtime["files"]:
                target = self.resources / validate_relative(item["path"])
                if "link" in item:
                    private_directory(target.parent)
                    link = validate_relative(item["link"])
                    if len(link.parts) != 1:
                        raise Failure("Unsafe pinned library alias")
                    if target.is_symlink() and os.readlink(target) == item["link"]:
                        continue
                    if os.path.lexists(target):
                        raise Failure("Unexpected existing runtime library alias")
                    target.symlink_to(item["link"])
                else:
                    original = source / item["path"]
                    if not original.exists() and "contentBase64" in item:
                        # The official archive's *_LICENSE glob omits two
                        # suffixed notices present in the official .app.
                        content = base64.b64decode(item["contentBase64"], validate=True)
                        if len(content) != item["size"] or hashlib.sha256(content).hexdigest() != item["sha256"]:
                            raise Failure("Pinned embedded license failed SHA256")
                        atomic_bytes(target, content)
                    else:
                        self.clone_verified(original, target, item["sha256"], item["size"], item.get("executable", False))
            atomic_bytes(self.resources / "LICENSE.ollama", self.runtime["licenseText"].encode())
        finally:
            if temporary is not None:
                temporary.cleanup()

    def download(self, url, destination, digest, size):
        if not HEX.fullmatch(digest):
            raise Failure("Invalid download digest")
        parsed = urllib.parse.urlparse(url)
        if parsed.scheme != "https" or parsed.username or parsed.password:
            raise Failure("Downloads require credential-free HTTPS")
        safe_file(destination)
        if destination.exists() and destination.stat().st_size == size and sha256(destination) == digest:
            return
        private_directory(destination.parent)
        partial = safe_file(destination.with_name(destination.name + ".partial"))
        offset = partial.stat().st_size if partial.exists() else 0
        if offset > size:
            raise Failure("Partial download exceeds pinned size; inspect it before retrying")
        if offset == size:
            if sha256(partial) != digest:
                raise Failure("Completed partial download failed SHA256; inspect it before retrying")
            os.replace(partial, destination)
            return
        if shutil.disk_usage(destination.parent).free < size - offset + 64 * 1024 * 1024:
            raise Failure("Not enough disk space for the pinned download")
        headers = {"User-Agent": "Bavbav-LocalAI/0.1.0"}
        if offset:
            headers["Range"] = "bytes=" + str(offset) + "-"
        request = urllib.request.Request(url, headers=headers)
        diagnostic("Downloading pinned public asset: " + destination.name)
        try:
            opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
            with opener.open(request, timeout=45) as response:
                final = urllib.parse.urlparse(response.url)
                if final.scheme != "https" or final.username or final.password:
                    raise Failure("Rejected non-HTTPS download redirect")
                append = bool(offset and response.status == 206)
                if append and not response.headers.get("Content-Range", "").startswith("bytes " + str(offset) + "-"):
                    raise Failure("Download resume range mismatch")
                received = offset if append else 0
                with open(partial, "ab" if append else "wb") as target:
                    os.chmod(partial, 0o600)
                    while True:
                        block = response.read(1024 * 1024)
                        if not block:
                            break
                        received += len(block)
                        if received > size:
                            raise Failure("Download exceeds pinned asset size")
                        target.write(block)
                    target.flush()
                    os.fsync(target.fileno())
            if partial.stat().st_size != size or sha256(partial) != digest:
                raise Failure("Download incomplete or SHA256 mismatch; no asset was installed")
            os.replace(partial, destination)
        except (urllib.error.URLError, TimeoutError, OSError) as error:
            raise Failure("Download interrupted; verified local tasks can still work. Retry explicitly to resume: " + str(error))

    def setup(self, allow_download=False):
        if platform.system() != "Darwin" or platform.machine() not in ("arm64", "x86_64"):
            raise Failure("This pinned runtime supports macOS Apple Silicon/Intel only")
        self.lock_operation()
        if self.verified()[0]:
            return self.status()
        self.provision_runtime(allow_download)
        source_models = Path.home() / ".ollama/models"
        # A wrapper may include the exact original API manifest as a layer. Both
        # are pinned; API reports the inner digest while disk stores wrapper.
        # Content-addressed blobs can be reused even if a user's mutable global
        # tag later changes. Every byte is verified against our fixed lock, and
        # our own exact manifest is installed; the mutable tag is never copied.
        for layer in self.layers:
            target = self.models / "blobs" / layer["digest"].replace(":", "-")
            source = source_models / "blobs" / layer["digest"].replace(":", "-")
            digest = layer["digest"][7:]
            if target.exists() and target.stat().st_size == layer["size"] and sha256(target) == digest:
                continue
            if source.is_file():
                diagnostic("Verifying and cloning local model layer " + digest[:12])
                self.clone_verified(source, target, digest, layer["size"])
            elif allow_download:
                url = "https://registry.ollama.ai/v2/huihui_ai/qwen3-abliterated/blobs/sha256:" + digest
                self.download(url, target, digest, layer["size"])
            else:
                raise Failure("Exact local model asset is missing; explicit --allow-download is required")
        atomic_bytes(self.model_manifest_path(), self.manifest)
        self.write_receipt("verified-local-clone-or-pinned-download")
        good, reason = self.verified(full=True)
        if not good:
            raise Failure(reason)
        return self.status()

    def owned_process(self):
        try:
            state = read_json(safe_file(self.process_state))
            pid = state["pid"]
            if not isinstance(pid, int) or pid < 2 or state["endpoint"] != ENDPOINT:
                return None
            if state["executable"] != str(self.binary):
                return None
            os.kill(pid, 0)
            if platform.system() == "Darwin":
                libproc = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
                buffer = ctypes.create_string_buffer(4096)
                if libproc.proc_pidpath(pid, buffer, len(buffer)) <= 0:
                    return None
                executable = buffer.value.decode()
            else:
                executable = os.readlink("/proc/" + str(pid) + "/exe")
            birth = subprocess.run(["/bin/ps", "-p", str(pid), "-o", "lstart="],
                                   text=True, capture_output=True, timeout=3).stdout.strip()
            owner = subprocess.run(["/bin/ps", "-p", str(pid), "-o", "uid="],
                                   text=True, capture_output=True, timeout=3).stdout.strip()
            if executable != str(self.binary) or birth != state["processBirth"] or owner != str(os.getuid()):
                return None
            return state
        except (OSError, ValueError, KeyError, Failure, subprocess.SubprocessError):
            return None

    def api(self, path, payload=None, timeout=3):
        data = None if payload is None else json.dumps(payload).encode()
        request = urllib.request.Request(ENDPOINT + path, data=data,
                                         headers={"Content-Type": "application/json"})
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        with opener.open(request, timeout=timeout) as response:
            body = response.read(MAX_JSON + 1)
        if len(body) > MAX_JSON:
            raise Failure("Local provider returned an oversized response")
        return json.loads(body)

    def listener_is_owned(self, pid):
        if platform.system() != "Darwin":
            return True
        result = subprocess.run(["/usr/sbin/lsof", "-nP", "-a", "-p", str(pid), "-iTCP:" + str(PORT),
                                 "-sTCP:LISTEN", "-Fn"], text=True, capture_output=True, timeout=3)
        names = [s[1:] for s in result.stdout.splitlines() if s.startswith("n")]
        return names == [HOST + ":" + str(PORT)]

    def status(self):
        installed, reason = self.verified()
        state = self.owned_process() if self.process_state.exists() else None
        running = False
        loaded = []
        if state and self.listener_is_owned(state["pid"]):
            try:
                running = self.api("/api/version").get("version") == self.runtime["version"]
                loaded = [{"name": item.get("name"), "size": item.get("size"),
                           "sizeVRAM": item.get("size_vram")} for item in self.api("/api/ps").get("models", [])]
            except (OSError, ValueError, urllib.error.URLError):
                pass
        return {"ok": True, "installed": installed, "running": running, "model": MODEL,
                "modelDigest": self.model["apiDigest"], "runtimeVersion": self.runtime["version"],
                "endpoint": ENDPOINT, "root": str(self.root), "reason": reason,
                "ownedPID": state["pid"] if state else None, "loadedModels": loaded,
                "cloudEnabled": False, "contextLength": 4096, "maxContextLength": 8192}

    def start(self):
        self.lock_operation()
        good, reason = self.verified()
        if not good:
            raise Failure("Local AI is not installed: " + reason)
        state = self.owned_process()
        if state:
            result = self.status()
            if not result["running"]:
                raise Failure("Owned provider process exists but is not healthy; explicit stop/retry is required")
            return result
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
            try:
                probe.bind((HOST, PORT))
            except OSError:
                raise Failure("Port 11439 is occupied by an unowned process; it will not be reused or stopped")
        private_directory(self.root / "home")
        private_directory(self.root / "tmp")
        env = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": str(self.root / "home"),
               "TMPDIR": str(self.root / "tmp"), "LANG": "en_US.UTF-8",
               "OLLAMA_HOST": HOST + ":" + str(PORT), "OLLAMA_MODELS": str(self.models),
               "OLLAMA_NO_CLOUD": "1", "OLLAMA_NOHISTORY": "1", "OLLAMA_NOPRUNE": "1",
               "OLLAMA_NUM_PARALLEL": "1", "OLLAMA_MAX_LOADED_MODELS": "1",
               "OLLAMA_MAX_QUEUE": "1", "OLLAMA_CONTEXT_LENGTH": "4096",
               "OLLAMA_KEEP_ALIVE": "0", "OLLAMA_ORIGINS": "http://127.0.0.1",
               "OLLAMA_FLASH_ATTENTION": "1"}
        log = open(safe_file(self.root / "server.log"), "ab", buffering=0)
        os.chmod(self.root / "server.log", 0o600)
        process = subprocess.Popen([str(self.binary), "serve"], cwd=self.root, env=env,
                                   stdin=subprocess.DEVNULL, stdout=log, stderr=log,
                                   start_new_session=True, close_fds=True)
        log.close()
        birth = subprocess.run(["/bin/ps", "-p", str(process.pid), "-o", "lstart="],
                               text=True, capture_output=True, timeout=3).stdout.strip()
        atomic_json(self.process_state, {"pid": process.pid, "executable": str(self.binary),
                    "processBirth": birth, "endpoint": ENDPOINT, "startedAt": time.time()})
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline:
            if process.poll() is not None:
                raise Failure("Owned provider exited during startup; inspect private Runtime/LocalAI/server.log")
            try:
                if self.listener_is_owned(process.pid) and self.api("/api/version").get("version") == self.runtime["version"]:
                    return self.status()
            except (OSError, ValueError, urllib.error.URLError):
                pass
            time.sleep(0.1)
        raise Failure("Owned provider startup timed out; no fallback provider was used")

    def stop(self):
        self.lock_operation()
        state = self.owned_process()
        if not state:
            return {"ok": True, "stopped": False, "reason": "No verified owned process exists"}
        pid = state["pid"]
        # No process-group signal and never shared daemon port 11434.
        os.kill(pid, signal.SIGTERM)
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            if not self.owned_process():
                return {"ok": True, "stopped": True, "pid": pid}
            time.sleep(0.1)
        raise Failure("Owned server is still stopping; no force-kill was attempted")


def self_check():
    """Small offline fixtures only: no real runtime/model copy, load, or daemon."""
    checks = 0
    def expect(condition, message):
        nonlocal checks
        if not condition:
            raise Failure("Fixture failed: " + message)
        checks += 1
    with tempfile.TemporaryDirectory(prefix="bavbav-local-ai-check-") as temporary:
        root = Path(temporary).resolve()
        os.chmod(root, 0o700)
        private_directory(root / "private")
        atomic_json(root / "private/state.json", {"safe": True})
        expect(read_json(root / "private/state.json")["safe"], "atomic JSON")
        expect((root / "private/state.json").stat().st_mode & 0o077 == 0, "private file")
        expect(sha256(root / "private/state.json") == hashlib.sha256((root / "private/state.json").read_bytes()).hexdigest(), "SHA256")
        for bad in ["../escape", "/absolute", "a/../../escape"]:
            try:
                validate_relative(bad)
            except Failure:
                checks += 1
            else:
                raise Failure("Unsafe relative path accepted")
        (root / "link").symlink_to(root / "private", target_is_directory=True)
        try:
            private_directory(root / "link/new")
        except Failure:
            checks += 1
        else:
            raise Failure("Symlink traversal accepted")
        (root / "public").mkdir(mode=0o755)
        os.chmod(root / "public", 0o755)
        try:
            private_directory(root / "public")
        except Failure:
            checks += 1
        else:
            raise Failure("Public writable runtime folder accepted")
        expect(ENDPOINT == "http://127.0.0.1:11439", "loopback endpoint")
        expect(MODEL == "huihui_ai/qwen3-abliterated:14b-v2", "exact model")
        listener_installer = Installer.__new__(Installer)
        if platform.system() == "Darwin":
            with mock.patch.object(subprocess, "run", return_value=mock.Mock(stdout="p123\nn127.0.0.1:11439\n")) as probe:
                expect(listener_installer.listener_is_owned(123), "numeric owned loopback listener")
                expect("-nP" in probe.call_args.args[0], "lsof cannot resolve localhost or service aliases")
            with mock.patch.object(subprocess, "run", return_value=mock.Mock(stdout="p123\nn*:11439\n")):
                expect(not listener_installer.listener_is_owned(123), "wildcard listener rejected")
        source = root / "source.bin"
        source.write_bytes(b"Bavbav small pinned fixture\n")
        target = root / "private/cloned.bin"
        installer = Installer.__new__(Installer)
        digest = sha256(source)
        installer.clone_verified(source, target, digest, source.stat().st_size)
        expect(target.read_bytes() == source.read_bytes(), "clone bytes")
        expect(target.stat().st_ino != source.stat().st_ino, "clone is not a hard link")
        expect(target.stat().st_nlink == 1, "private independent clone")
        installer.resources = root / "private"
        installer.runtime = {"files": [{"path": "cloned.bin"}, {"path": "alias.0", "link": "cloned.bin"},
                                        {"path": "alias", "link": "alias.0"}]}
        (root / "private/alias.0").symlink_to("cloned.bin")
        (root / "private/alias").symlink_to("alias.0")
        installer.validate_runtime_links()
        checks += 1
        (root / "private/alias").unlink()
        (root / "private/alias").symlink_to("../source.bin")
        try:
            installer.validate_runtime_links()
        except Failure:
            checks += 1
        else:
            raise Failure("Unpinned escaping library link accepted")
        try:
            installer.clone_verified(source, target, "0" * 64, source.stat().st_size)
        except Failure:
            checks += 1
        else:
            raise Failure("Wrong source digest accepted")
        expect(target.read_bytes() == source.read_bytes(), "invalid clone preserves prior asset")
        source_link = root / "source-link.bin"
        source_link.symlink_to(source)
        try:
            installer.clone_verified(source_link, target, digest, source.stat().st_size)
        except Failure:
            checks += 1
        else:
            raise Failure("Symlink source accepted")
        body = b"Pinned download fixture\n"
        body_digest = hashlib.sha256(body).hexdigest()
        destination = root / "private/download.bin"
        partial = destination.with_name(destination.name + ".partial")
        class Response:
            url = "https://registry.ollama.ai/pinned-fixture"
            def __init__(self, data, status=200, headers=None):
                self.data = data
                self.status = status
                self.headers = headers or {}
            def __enter__(self):
                return self
            def __exit__(self, *_):
                return False
            def read(self, count):
                block, self.data = self.data[:count], self.data[count:]
                return block
        def fake_download(response):
            opener = mock.Mock()
            opener.open.return_value = response
            return mock.patch.object(urllib.request, "build_opener", return_value=opener)
        partial.write_bytes(body[:7])
        with fake_download(Response(body[7:], 206, {"Content-Range": "bytes 7-22/23"})):
            installer.download(Response.url, destination, body_digest, len(body))
        expect(destination.read_bytes() == body, "resumed pinned download")
        expect(not partial.exists(), "partial atomically promoted")
        destination.unlink()
        partial.write_bytes(body[:3])
        with fake_download(Response(body, 200)):
            installer.download(Response.url, destination, body_digest, len(body))
        expect(destination.read_bytes() == body, "server ignored range safely restarts")
        destination.unlink()
        partial.write_bytes(body)
        installer.download(Response.url, destination, body_digest, len(body))
        expect(destination.read_bytes() == body, "completed partial requires no network")
        destination.unlink()
        with fake_download(Response(body + b"oversize")):
            try:
                installer.download(Response.url, destination, body_digest, len(body))
            except Failure:
                checks += 1
            else:
                raise Failure("Oversized download accepted")
        expect(not destination.exists(), "oversized download never installed")
        try:
            installer.download("http://registry.ollama.ai/unsafe", destination, body_digest, len(body))
        except Failure:
            checks += 1
        else:
            raise Failure("Plain HTTP download accepted")
    return {"ok": True, "checks": checks, "fixtureOnly": True,
            "modelLoaded": False, "globalDaemonTouched": False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", default=str(Path(__file__).resolve().parent.parent))
    commands = parser.add_subparsers(dest="action", required=True)
    for action in ("status", "setup", "start", "stop", "verify", "check"):
        command = commands.add_parser(action)
        if action == "setup":
            command.add_argument("--allow-download", action="store_true",
                                 help="Explicitly allow pinned public HTTPS downloads if local assets are missing")
    args = parser.parse_args()
    os.umask(0o077)
    try:
        if args.action == "check":
            result = self_check()
        else:
            installer = Installer(args.repo)
            if args.action == "setup":
                result = installer.setup(args.allow_download)
            elif args.action == "verify":
                good, reason = installer.verified(full=True)
                result = {"ok": good, "verified": good, "reason": reason, "model": MODEL}
            else:
                result = getattr(installer, args.action)()
        print(json.dumps(result, separators=(",", ":")), flush=True)
        return 0 if result.get("ok") else 1
    except (Failure, OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        print(json.dumps({"ok": False, "error": str(error), "model": MODEL,
                          "endpoint": ENDPOINT}, separators=(",", ":")), flush=True)
        return 1


if __name__ == "__main__":
    sys.exit(main())
