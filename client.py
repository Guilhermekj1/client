#!/usr/bin/env python3
import argparse
import ctypes
import hashlib
import json
import os
import select
import time
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import Request, urlopen


DEFAULT_URL = "https://servidorsync.onrender.com"


def file_hash(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def scan_folder(folder):
    files = {}
    for current, dirs, names in os.walk(folder, followlinks=False):
        dirs[:] = [name for name in dirs if not (Path(current) / name).is_symlink()]
        for name in names:
            path = Path(current) / name
            if path.is_symlink() or name.endswith(".synctk-tmp") or not path.is_file():
                continue
            relative = path.relative_to(folder).as_posix()
            stat = path.stat()
            files[relative] = {
                "sha256": file_hash(path),
                "size": stat.st_size,
                "mtime": stat.st_mtime,
                "path": path,
            }
    return files


class SyncClient:
    def __init__(self, base_url, token=None):
        self.base_url = base_url.rstrip("/")
        self.token = token

    def request(self, method, path, body=None, headers=None):
        request_headers = dict(headers or {})
        if self.token:
            request_headers["Authorization"] = "Bearer " + self.token
        request = Request(self.base_url + path, data=body, headers=request_headers, method=method)
        try:
            with urlopen(request, timeout=60) as response:
                return response.read()
        except HTTPError as error:
            message = error.read().decode("utf-8", errors="replace")
            raise RuntimeError(f"Server returned HTTP {error.code}: {message}") from error
        except URLError as error:
            raise RuntimeError(f"Could not reach sync server: {error.reason}") from error

    def manifest(self):
        return json.loads(self.request("GET", "/api/manifest"))

    def wait_for_changes(self, revision):
        query = urlencode({"after": revision, "timeout": 20})
        return json.loads(self.request("GET", "/api/changes?" + query))

    def download(self, relative):
        query = urlencode({"path": relative})
        return self.request("GET", "/api/file?" + query)

    def upload(self, relative, local_file, mtime):
        query = urlencode({"path": relative})
        self.request(
            "PUT",
            "/api/file?" + query,
            body=local_file.read_bytes(),
            headers={
                "Content-Type": "application/octet-stream",
                "X-Modified-At": str(mtime),
            },
        )

    def delete(self, relative):
        payload = json.dumps({"path": relative, "mtime": time.time()}).encode("utf-8")
        self.request("POST", "/api/delete", body=payload, headers={"Content-Type": "application/json"})


def apply_remote(client, folder, relative, remote):
    relative_path = Path(relative)
    if relative_path.is_absolute() or ".." in relative_path.parts or "\\" in relative:
        raise RuntimeError(f"Server returned an invalid path: {relative}")
    local_path = folder.joinpath(*relative_path.parts)
    if not local_path.resolve().is_relative_to(folder):
        raise RuntimeError(f"Refusing to access a path outside the sync folder: {relative}")
    if remote["deleted"]:
        if local_path.is_symlink():
            raise RuntimeError(f"Refusing to delete symlink: {local_path}")
        if local_path.is_file():
            local_path.unlink()
        parent = local_path.parent
        while parent != folder and parent.exists():
            try:
                parent.rmdir()
            except OSError:
                break
            parent = parent.parent
        print(f"Deleted {relative}")
        return
    content = client.download(relative)
    local_path.parent.mkdir(parents=True, exist_ok=True)
    if local_path.is_symlink():
        raise RuntimeError(f"Refusing to overwrite symlink: {local_path}")
    temporary = local_path.with_name(local_path.name + ".synctk-tmp")
    temporary.write_bytes(content)
    temporary.replace(local_path)
    os.utime(local_path, (remote["mtime"], remote["mtime"]))
    print(f"Downloaded {relative}")


def sync_once(client, folder, state_file):
    folder.mkdir(parents=True, exist_ok=True)
    if state_file.exists():
        state = json.loads(state_file.read_text(encoding="utf-8"))
    else:
        state = {"entries": {}}
    baseline = state.get("entries", {})
    remote_state = client.manifest()
    remote_entries = remote_state["entries"]
    local_files = scan_folder(folder)

    for relative in sorted(set(local_files) | set(remote_entries) | set(baseline)):
        local = local_files.get(relative)
        remote = remote_entries.get(relative)
        base = baseline.get(relative)

        if local and remote and not remote["deleted"] and local["sha256"] == remote["sha256"]:
            continue

        local_changed = (
            (local is not None and base is None)
            or (
                base is not None
                and (
                    (base["deleted"] and local is not None)
                    or (
                        not base["deleted"]
                        and (
                            local is None
                            or local["sha256"] != base["sha256"]
                        )
                    )
                )
            )
        )
        remote_changed = (
            (remote is not None and base is None)
            or (
                remote is not None
                and base is not None
                and remote["revision"] != base["revision"]
            )
        )

        if local_changed and remote_changed:
            local_mtime = local["mtime"] if local else time.time()
            if local_mtime > remote["mtime"]:
                if local:
                    client.upload(relative, local["path"], local["mtime"])
                else:
                    client.delete(relative)
            else:
                apply_remote(client, folder, relative, remote)
        elif local_changed:
            if local:
                client.upload(relative, local["path"], local["mtime"])
                print(f"Uploaded {relative}")
            else:
                client.delete(relative)
                print(f"Deleted {relative}")
        elif remote_changed:
            apply_remote(client, folder, relative, remote)

    # Record the server state that actually matches the local files. Keep the
    # earlier cursor so server changes arriving during this pass are noticed.
    final_entries = client.manifest()["entries"]
    final_local = scan_folder(folder)
    next_baseline = {}
    for relative in set(remote_entries) | set(final_entries) | set(baseline):
        final = final_entries.get(relative)
        local = final_local.get(relative)
        if final is not None and (
            (final["deleted"] and local is None)
            or (not final["deleted"] and local is not None and local["sha256"] == final["sha256"])
        ):
            next_baseline[relative] = final
        elif relative in remote_entries:
            next_baseline[relative] = remote_entries[relative]
        elif relative in baseline:
            next_baseline[relative] = baseline[relative]

    state_file.parent.mkdir(parents=True, exist_ok=True)
    temporary = state_file.with_suffix(".tmp")
    temporary.write_text(json.dumps({"entries": next_baseline}, separators=(",", ":")), encoding="utf-8")
    temporary.replace(state_file)
    return remote_state["revision"]


class DirectoryWatcher:
    MASK = 0x00000002 | 0x00000004 | 0x00000008 | 0x00000040 | 0x00000080 | 0x00000100 | 0x00000200 | 0x00000400 | 0x00000800

    def __init__(self, folder):
        self.folder = folder
        self.libc = ctypes.CDLL(None, use_errno=True)
        self.fd = self.libc.inotify_init1(os.O_CLOEXEC)
        if self.fd < 0:
            error = ctypes.get_errno()
            raise OSError(error, os.strerror(error))
        self.libc.inotify_add_watch.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_uint32]
        self.libc.inotify_add_watch.restype = ctypes.c_int
        self.refresh()

    def refresh(self):
        for current, dirs, _ in os.walk(self.folder, followlinks=False):
            dirs[:] = [name for name in dirs if not (Path(current) / name).is_symlink()]
            result = self.libc.inotify_add_watch(self.fd, os.fsencode(current), self.MASK)
            if result < 0:
                error = ctypes.get_errno()
                raise OSError(error, os.strerror(error), current)

    def wait(self):
        select.select([self.fd], [], [])
        os.read(self.fd, 1024 * 1024)
        time.sleep(0.25)
        while select.select([self.fd], [], [], 0)[0]:
            os.read(self.fd, 1024 * 1024)
            time.sleep(0.1)
            if not select.select([self.fd], [], [], 0)[0]:
                break


class PollingWatcher:
    def __init__(self, folder):
        self.folder = folder
        self.refresh()

    def refresh(self):
        entries = {}
        for current, dirs, names in os.walk(self.folder, followlinks=False):
            dirs[:] = [name for name in dirs if not (Path(current) / name).is_symlink()]
            for name in dirs:
                path = Path(current) / name
                entries[path.relative_to(self.folder).as_posix() + "/"] = None
            for name in names:
                path = Path(current) / name
                if path.is_symlink() or name.endswith(".synctk-tmp"):
                    continue
                try:
                    stat = path.stat()
                except FileNotFoundError:
                    continue
                entries[path.relative_to(self.folder).as_posix()] = (stat.st_size, stat.st_mtime_ns)
        self.snapshot = entries

    def wait(self):
        while True:
            time.sleep(0.5)
            previous = self.snapshot
            self.refresh()
            if self.snapshot != previous:
                return


def watch_server(client, folder, state_file, sync_lock, cursor):
    while True:
        try:
            update = client.wait_for_changes(cursor)
            if update["revision"] > cursor:
                with sync_lock:
                    cursor = sync_once(client, folder, state_file)
        except (RuntimeError, OSError, ValueError, KeyError) as error:
            print(f"Server update check failed: {error}")
            time.sleep(3)


def main():
    parser = argparse.ArgumentParser(description="Synchronize a local folder with the SyncTK server.")
    parser.add_argument("--url", default=DEFAULT_URL, help=f"Server URL (default: {DEFAULT_URL})")
    parser.add_argument("--folder", default=str(Path.home() / "Aoba"), help="Folder to synchronize (default: ~/Aoba)")
    parser.add_argument("--once", action="store_true", help="Synchronize once and exit")
    args = parser.parse_args()
    folder = Path(args.folder).expanduser().resolve()
    state_key = hashlib.sha256((args.url.rstrip("/") + str(folder)).encode()).hexdigest()[:16]
    state_file = Path.home() / ".synctk" / f"state-{state_key}.json"
    client = SyncClient(args.url, os.environ.get("SYNCTK_TOKEN"))

    try:
        cursor = sync_once(client, folder, state_file)
    except (RuntimeError, OSError, ValueError, KeyError) as error:
        print(f"Sync failed: {error}")
        if args.once:
            raise SystemExit(1)
        cursor = 0

    if args.once:
        return

    import threading

    sync_lock = threading.Lock()
    threading.Thread(
        target=watch_server,
        args=(client, folder, state_file, sync_lock, cursor),
        daemon=True,
    ).start()

    while True:
        try:
            try:
                watcher = DirectoryWatcher(folder)
            except (AttributeError, OSError):
                watcher = PollingWatcher(folder)
                print("Filesystem notifications unavailable; checking local changes twice per second.")
            print(f"Watching {folder}; remote changes are delivered by the server.")
            while True:
                watcher.wait()
                with sync_lock:
                    watcher.refresh()
                    cursor = sync_once(client, folder, state_file)
        except (OSError, RuntimeError, ValueError, KeyError) as error:
            print(f"Local watch/sync failed: {error}; retrying in 3 seconds")
            time.sleep(3)


if __name__ == "__main__":
    main()
