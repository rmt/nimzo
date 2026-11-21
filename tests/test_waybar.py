#!/usr/bin/env python3
"""Run a real Waybar on two private headless outputs; no desktop is required.
Usage: python3 tests/test_waybar.py waybar zone-client state-client nimzo
"""
import json
import os
from pathlib import Path
import socket
from shutil import which
import struct
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent
HEADER = struct.Struct("=II")


def receive(sock):
    def exact(count):
        data = b""
        while len(data) < count:
            chunk = sock.recv(count - len(data))
            if not chunk:
                raise RuntimeError("IPC disconnected")
            data += chunk
        return data
    assert exact(6) == b"i3-ipc"
    length, kind = HEADER.unpack(exact(8))
    return kind, json.loads(exact(length))


def request(path, kind, text=""):
    with socket.socket(socket.AF_UNIX) as sock:
        sock.settimeout(3)
        sock.connect(str(path))
        payload = text.encode()
        sock.sendall(b"i3-ipc" + HEADER.pack(len(payload), kind) + payload)
        response, data = receive(sock)
        assert response == kind, (response, kind, data)
        return data


def until(check, label):
    deadline = time.monotonic() + 8
    while time.monotonic() < deadline:
        result = check()
        if result:
            return result
        time.sleep(0.05)
    raise AssertionError("Timed out: " + label)


def leaves(node):
    if node["type"] in ("con", "floating_con"):
        yield node
    for key in ("nodes", "floating_nodes"):
        for child in node.get(key, []):
            yield from leaves(child)


def main(restricted=False):
    processes = []
    with tempfile.TemporaryDirectory(prefix="nimzo-waybar-") as directory:
        runtime = Path(directory)
        config = runtime / "config"
        base_config = """output HEADLESS-1 default
output HEADLESS-1 mode 800x600
output HEADLESS-1 position 0 0
output HEADLESS-2 mode 800x600
output HEADLESS-2 enable
output HEADLESS-2 position 0 600
"""
        if restricted:
            base_config += "sway_ipc_restricted on\n"
        base_config += f'exec printf %s "$SWAYSOCK" > "{runtime / "swaysock"}"\n'
        def profile(name, caps, executable, *args):
            argv = (str(Path(executable).absolute()), *map(str, args))
            return f"wayland_client {name} {caps} " + " ".join(
                json.dumps(arg, ensure_ascii=False) for arg in argv) + "\n"

        waybar = which(sys.argv[1])
        assert waybar, f"Waybar not found: {sys.argv[1]}"
        base_config += profile("bar", "toplevel", waybar, "-c", ROOT / "examples/waybar.jsonc",
                               "-s", ROOT / "examples/waybar.css", "-l", "trace" if restricted else "debug")
        base_config += "launch bar\n"
        state_reply = runtime / "state-reply"
        for action in ("state", "activate"):
            base_config += profile(action, "toplevel", sys.argv[3], "waybar-test", action, state_reply)
        proof_dir = os.environ.get("NIMZO_WAYBAR_PROOF")
        if proof_dir and not restricted:
            grim = which("grim")
            assert grim, "NIMZO_WAYBAR_PROOF requires grim"
            Path(proof_dir).mkdir(parents=True, exist_ok=True)
            for name, output in (("HEADLESS-1", "HEADLESS-1"), ("HEADLESS-2", "HEADLESS-2"),
                                 ("minimized", "HEADLESS-2")):
                base_config += profile(name, "capture", grim, "-o", output,
                                       Path(proof_dir) / (name + ".png"))

        def window_state(action, expected):
            state_reply.unlink(missing_ok=True)
            assert request(path, 0, "launch " + action)[0]["success"]
            until(lambda: state_reply.exists() and state_reply.read_text().strip() == expected,
                  "trusted taskbar client response")
        config.write_text(base_config)
        env = dict(os.environ, XDG_RUNTIME_DIR=directory, WLR_BACKENDS="headless",
                   WLR_HEADLESS_OUTPUTS="2", WLR_RENDERER="pixman",
                   GDK_BACKEND="wayland", NO_AT_BRIDGE="1")
        env.pop("DISPLAY", None)
        for name in ("WAYLAND_DISPLAY", "WAYLAND_SOCKET", "SWAYSOCK", "I3SOCK"):
            env.pop(name, None)
        with open(runtime / "compositor.log", "w+") as log:
            compositor = subprocess.Popen([sys.argv[4], "-c", str(config)],
                                          env=env, stdout=log if restricted else subprocess.DEVNULL,
                                          stderr=log)
            processes.append(compositor)
            try:
                path = runtime / ("nimzo-ipc." + str(compositor.pid) + ".sock")
                until(path.exists, "SWAYSOCK creation")
                if not restricted:
                    until(lambda: len(request(path, 3)) == 2, "two outputs")
                until((runtime / "swaysock").exists, "startup socket environment")
                assert (runtime / "swaysock").read_text() == str(path)
                if not restricted:
                    assert request(path, 9)["config"] == base_config
                assert {w["name"] for w in request(path, 1)} == {"HEADLESS-1:1", "HEADLESS-2:1"}
                if not restricted:
                    assert all(o["current_workspace"] == o["name"] + ":1" for o in request(path, 3))
                env["SWAYSOCK"] = env["I3SOCK"] = str(path)
                env["WAYLAND_DISPLAY"] = until(
                    lambda: next((p.name for p in runtime.glob("wayland-*") if not p.name.endswith(".lock")), None),
                    "Wayland socket")
                # Occupied tags expose usable rectangles; empty tags stay absent.
                assert request(path, 0, 'workspace --no-auto-back-and-forth "HEADLESS-2:3"')[0]["success"]
                probe = subprocess.Popen([sys.argv[2], "panel-probe"], env=env,
                                         stdout=subprocess.DEVNULL, stderr=log)
                processes.append(probe)
                until(lambda: any(n.get("app_id") == "panel-probe"
                                  for n in leaves(request(path, 4))), "secondary probe")
                assert request(path, 0, 'workspace "HEADLESS-1:2"')[0]["success"]
                client = subprocess.Popen([sys.argv[2], "waybar-test"], env=env,
                                          stdout=subprocess.DEVNULL, stderr=log)
                processes.append(client)
                tree = until(lambda: (t if any(n.get("app_id") == "waybar-test" for n in leaves(t)) else None)
                             if (t := request(path, 4)) else None, "real client in IPC tree")
                window = next(n for n in leaves(tree) if n.get("app_id") == "waybar-test")
                def panels_reserved():
                    workspaces = request(path, 1)
                    return len(workspaces) == 2 and all(
                        0 < item["rect"]["height"] < 600 for item in workspaces)
                until(panels_reserved, "Waybar exclusive zones on BOTH outputs")
                if restricted:
                    until(lambda: "node (focused) found" in (runtime / "compositor.log").read_text(),
                          "Waybar focused-window module reading the tree")
                    assert "Unable to subscribe ipc event" not in (runtime / "compositor.log").read_text()
                    for command in ("exec true", "launch state", "reload", "exit", "kill"):
                        assert not request(path, 0, command)[0]["success"], command
                    assert not request(path, 9)["success"]
                    assert {w["name"] for w in request(path, 1)} == {"HEADLESS-1:2", "HEADLESS-2:3"}
                    assert request(path, 0, 'workspace --no-auto-back-and-forth "HEADLESS-2:3"')[0]["success"]
                    assert next(w["name"] for w in request(path, 1) if w["focused"]) == "HEADLESS-2:3"
                    print("PASS: real Waybar with restricted IPC on both outputs")
                    return
                ids = {w["name"]: w["id"] for w in request(path, 1)}
                assert set(ids) == {"HEADLESS-1:2", "HEADLESS-2:3"}
                probe.terminate()
                probe.wait(timeout=3)
                until(lambda: not any(n.get("app_id") == "panel-probe"
                                      for n in leaves(request(path, 4))), "secondary probe close")
                assert {w["name"] for w in request(path, 1)} == set(ids)
                assert request(path, 0, 'workspace "HEADLESS-2:4"')[0]["success"]
                assert {w["name"] for w in request(path, 1)} == {"HEADLESS-1:2", "HEADLESS-2:4"}
                assert request(path, 0, 'workspace "HEADLESS-2:3"')[0]["success"]
                assert request(path, 0, 'focus output "HEADLESS-1"')[0]["success"]
                # A hidden tag with an assigned client must remain published.
                assert request(path, 0, "toggletag 4")[0]["success"]
                assert {w["name"] for w in request(path, 1)} == {"HEADLESS-1:2", "HEADLESS-1:4", "HEADLESS-2:3"}
                assert len(list(leaves(request(path, 4)))) == 1
                assert request(path, 0, "toggletag 4")[0]["success"]
                assert window["focused"] and window["name"] == "waybar-test", window
                original_id = window["id"]
                reply = request(path, 0, "move container to workspace HEADLESS-2:3")
                assert reply[0]["success"], reply
                moved = until(lambda: next((n for n in leaves(request(path, 4))
                                           if n["id"] == original_id and n["rect"]["y"] >= 600), None),
                              "client move to secondary output")
                assert moved["id"] == original_id
                assert {w["name"] for w in request(path, 1)} == set(ids)
                assert request(path, 0, 'workspace "HEADLESS-2:3"')[0]["success"]
                assert request(path, 0, "focus output next")[0]["success"]
                assert next(w["name"] for w in request(path, 1) if w["focused"]) == "HEADLESS-1:2"
                assert len(request(path, 1)) == 2, "each output must retain its selected tag"
                assert request(path, 0, "swap outputs")[0]["success"]
                assert {w["name"] for w in request(path, 1)} == {"HEADLESS-1:3", "HEADLESS-2:2"}
                assert next(n for n in leaves(request(path, 4)) if n["id"] == original_id)["rect"]["y"] < 600
                assert request(path, 0, "swap outputs HEADLESS-1 HEADLESS-2")[0]["success"]
                assert request(path, 0, 'focus output "HEADLESS-2"')[0]["success"]
                if proof_dir:
                    time.sleep(1.5)
                    for output in ["HEADLESS-1", "HEADLESS-2"]:
                        assert request(path, 0, "launch " + output)[0]["success"]
                        until(lambda: (Path(proof_dir) / (output + ".png")).exists(), "capture " + output)
                assert request(path, 0, "maximize toggle")[0]["success"]
                maximized = until(lambda: next((n for n in leaves(request(path, 4))
                                               if n["id"] == original_id and n["maximized"]), None),
                                  "maximized IPC state")
                assert maximized["rect"] == next(w["rect"] for w in request(path, 1)
                                                 if w["name"] == "HEADLESS-2:3")
                window_state("state", "0 1")
                assert request(path, 0, "minimize")[0]["success"]
                minimized = next(n for n in leaves(request(path, 4)) if n["id"] == original_id)
                assert minimized["minimized"] and not minimized["visible"] and not minimized["focused"]
                assert {w["name"] for w in request(path, 1)} == set(ids)
                window_state("state", "1 1")
                if proof_dir:
                    time.sleep(0.5)
                    assert request(path, 0, "launch minimized")[0]["success"]
                    until(lambda: (Path(proof_dir) / "minimized.png").exists(), "minimized capture")
                window_state("activate", "0 1")
                assert request(path, 0, "maximize toggle")[0]["success"]
                assert request(path, 0, "kill")[0]["success"]
                until(lambda: not list(leaves(request(path, 4))), "client close")
                assert {w["name"] for w in request(path, 1)} == set(ids), "selected empty tags must remain"
                config.write_text(base_config + "output HEADLESS-2 disable\n")
                assert request(path, 0, "reload")[0]["success"]
                until(lambda: sum(o["active"] for o in request(path, 3)) == 1, "output disable")
                config.write_text(base_config)
                assert request(path, 0, "reload")[0]["success"]
                until(lambda: all(o["active"] for o in request(path, 3)), "output re-enable")
                assert len(request(path, 1)) == 2
                assert request(path, 0, 'workspace "HEADLESS-2:3"')[0]["success"]
                replacement = subprocess.Popen([sys.argv[2], "replacement"], env=env,
                                               stdout=subprocess.DEVNULL, stderr=log)
                processes.append(replacement)
                until(lambda: any(n.get("app_id") == "replacement"
                                  for n in leaves(request(path, 4))), "tag recreation")
                recreated = request(path, 1)
                assert len(recreated) == 2
                assert next(w["id"] for w in recreated if w["name"] == "HEADLESS-2:3") == ids["HEADLESS-2:3"]
                until(lambda: 0 < next(w["rect"]["height"] for w in request(path, 1)
                                      if w["name"] == "HEADLESS-2:3") < 600,
                      "Waybar reservation on re-enabled output")
                assert not request(path, 0, "unsupported-command")[0]["success"]
                assert request(path, 0, "exit")[0]["success"]
                assert compositor.wait(timeout=5) == 0
                assert not path.exists(), "IPC socket was not removed"
                print("PASS: real Waybar on both outputs, exclusive zones, output-local workspace clicks, "
                      "real client tree/move/close, output disable/re-enable, socket cleanup")
            except BaseException:
                log.flush()
                print((runtime / "compositor.log").read_text(), file=sys.stderr)
                raise
            finally:
                for process in reversed(processes):
                    if process.poll() is None:
                        process.terminate()
                    try:
                        process.wait(timeout=3)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait()


if __name__ == "__main__":
    main()
    main(restricted=True)
