# SPDX-License-Identifier: 0BSD

"""Black-box regression tests using a small, socket-based Wayland test server.

Run after `nimble build`: python3 tests/test_protocol.py
No graphical session or installed River is required.
"""

import array
import json
import os
from pathlib import Path
import shlex
import socket
import struct
import subprocess
import sys
import tempfile
import time
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
U32 = struct.Struct("=I")
HEADER = struct.Struct("=II")
IPC_MAGIC = b"i3-ipc"
IPC_HEADER = struct.Struct("=II")
IPC_GET_TREE = 4
IPC_SUBSCRIBE = 2
IPC_COMMAND = 0
IPC_EVENT_WORKSPACE = 0x80000000


# Only the core requests used by nimzo are needed. River signatures are read
# from the same protocol files used to build the executable.
CORE = {
    "wl_display": [("sync", "n", "wl_callback"), ("get_registry", "n", "wl_registry")],
    "wl_registry": [("bind", "usun", None)],
    "wl_compositor": [("create_surface", "n", "wl_surface")],
    "wl_surface": [
        ("destroy", "", None), ("attach", "oii", None),
        ("damage", "iiii", None), ("frame", "n", "wl_callback"),
        ("set_opaque_region", "o", None), ("set_input_region", "o", None),
        ("commit", "", None),
    ],
    "wl_shm": [("create_pool", "nfi", "wl_shm_pool")],
    "wl_shm_pool": [
        ("create_buffer", "niiiiu", "wl_buffer"),
        ("destroy", "", None), ("resize", "i", None),
    ],
    "wl_buffer": [("destroy", "", None)],
}


def river_requests():
    result = {}
    for path in (ROOT / "protocol").glob("*.xml"):
        for interface in ET.parse(path).getroot().findall("interface"):
            requests = []
            for request in interface.findall("request"):
                args = request.findall("arg")
                signature = "".join({"uint": "u", "int": "i", "object": "o",
                                     "new_id": "n", "string": "s", "fd": "f",
                                     "fixed": "i", "array": "a"}[arg.get("type")]
                                    for arg in args)
                child = next((a.get("interface") for a in args
                              if a.get("type") == "new_id"), None)
                requests.append((request.get("name"), signature, child))
            result[interface.get("name")] = requests
    return result


def ipc_frame(message_type, payload=b""):
    return IPC_MAGIC + IPC_HEADER.pack(len(payload), message_type) + payload


def ipc_send(sock, message_type, payload=b""):
    sock.sendall(ipc_frame(message_type, payload))


def ipc_receive(sock):
    header = bytearray()
    while len(header) < len(IPC_MAGIC) + IPC_HEADER.size:
        data = sock.recv(len(IPC_MAGIC) + IPC_HEADER.size - len(header))
        if not data:
            raise AssertionError("IPC peer closed before a response")
        header.extend(data)
    if bytes(header[:len(IPC_MAGIC)]) != IPC_MAGIC:
        raise AssertionError(f"bad IPC magic: {header[:len(IPC_MAGIC)]!r}")
    length, message_type = IPC_HEADER.unpack_from(header, len(IPC_MAGIC))
    payload = bytearray()
    while len(payload) < length:
        data = sock.recv(length - len(payload))
        if not data:
            raise AssertionError("IPC peer closed in a response")
        payload.extend(data)
    return message_type, bytes(payload)


def ipc_json(sock, message_type, value=None):
    payload = b"" if value is None else json.dumps(value, separators=(",", ":")).encode()
    ipc_send(sock, message_type, payload)
    response_type, response = ipc_receive(sock)
    return response_type, json.loads(response)


def connect_ipc(path):
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        client.settimeout(5)
        try:
            client.connect(str(path))
            return client
        except (FileNotFoundError, ConnectionRefusedError):
            client.close()
            time.sleep(0.01)
    raise AssertionError(f"IPC socket was not ready: {path}")


def ipc_event(sock):
    message_type, payload = ipc_receive(sock)
    if message_type != IPC_EVENT_WORKSPACE:
        raise AssertionError(f"expected workspace event, got {message_type}")
    return json.loads(payload)


def tree_outputs(tree):
    return tree["nodes"]


def find_workspace(tree, name):
    for output in tree_outputs(tree):
        for workspace in output["nodes"]:
            if workspace.get("name") == name:
                return output, workspace
    raise AssertionError(f"workspace {name!r} not found in {tree!r}")


def find_window(workspace, title):
    for window in workspace["floating_nodes"]:
        if window.get("name") == title:
            return window
    raise AssertionError(f"window {title!r} not found in {workspace!r}")


def receive_tree(sock):
    response_type, payload = ipc_json(sock, IPC_GET_TREE)
    if response_type != IPC_GET_TREE:
        raise AssertionError(f"GET_TREE response had type {response_type}")
    return payload


class TestServer:
    def __init__(self, directory, initial_title=None, initial_app_id=None,
                 configuration=None, output_heads=None, defer_roundtrip=False,
                 layer_shell=False, logical_outputs=None, **environment):
        self.socket, client = socket.socketpair()
        self.socket.settimeout(5)
        self.data = bytearray()
        self.fds = []
        self.defer_roundtrip = defer_roundtrip
        self.deferred_syncs = []
        self.objects = {1: "wl_display"}
        self.signatures = CORE | river_requests()
        self.globals = {}
        self.requests = []
        self.request_phases = []
        self.last_cycle_phases = []
        self.last_key_phases = []
        self.keybindings = {}
        self.pointerbindings = {}
        self.output_heads = {}
        self.output_modes = {}
        self.output_configurations = {}
        self.output_config_heads = {}
        self.output_applications = []
        self.output_replies = []
        self.output_serial = 0
        self.advertise_output_manager = output_heads is not None
        self.advertise_layer_shell = layer_shell
        self.logical_outputs = list(logical_outputs or [])
        self.ipc_enabled = bool(environment.get("SWAYSOCK"))
        self.logical_output_names = [
            output.get("name", f"OUTPUT-{index + 1}")
            for index, output in enumerate(self.logical_outputs)
        ]
        self.logical_output_global_ids = []
        self.river_outputs = {}
        self.layer_outputs = {}
        self.layer_seats = {}
        self.pending_layer_events = []
        self.phase = "startup"
        self.config_path = Path(directory) / "river" / "nimzo.config"
        if configuration is not None:
            self.config_path.parent.mkdir()
            self.config_path.write_text(configuration)
        self.server_id = 0xFEFFFFFF
        self.storage_checks = 0
        self.images = []
        self.marker = Path(directory) / "spawned"
        foot = Path(directory) / "foot"
        foot.write_text('#!/bin/sh\nprintf "spawned\\n" >> "$TEST_FOOT_MARKER"\n')
        foot.chmod(0o700)
        env = dict(os.environ, WAYLAND_SOCKET=str(client.fileno()),
                   XDG_CONFIG_HOME=directory,
                   PATH=directory + os.pathsep + os.environ["PATH"],
                   TEST_FOOT_MARKER=str(self.marker))
        env.pop("SWAYSOCK", None)
        env.update(environment)
        self.process = subprocess.Popen([str(ROOT / "nimzo")], env=env,
                                        pass_fds=(client.fileno(),),
                                        stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        client.close()
        self.until(lambda: len(self.globals) ==
                   4 + int(self.advertise_output_manager) + int(self.advertise_layer_shell) +
                   (len(self.logical_outputs) if self.ipc_enabled else 0))
        self.wm = self.globals["river_window_manager_v1"]
        if self.advertise_output_manager:
            for head in output_heads:
                self.add_output(**head)
            self.outputs_done()
        for output in self.logical_outputs:
            self.add_logical_output(**output)
        self.seat = self.new_object("river_seat_v1")
        self.window = self.new_object("river_window_v1")
        self.event(self.wm, 8, self.seat)  # seat
        self.event(self.wm, 6, self.window)  # window
        self.event(self.window, 6, 3)  # decoration_hint: no_preference
        if initial_app_id is not None:
            self.event(self.window, 3, initial_app_id)  # app_id
        if initial_title is not None:
            self.event(self.window, 4, initial_title)  # title
        self.cycle(dimensions=(640, 480))
        for callback in self.deferred_syncs:
            self.event(callback, 0, 1)
            self.event(1, 1, callback)
        self.deferred_syncs = []
        self.defer_roundtrip = False

    def close(self):
        if self.socket.fileno() == -1:
            return
        self.socket.close()
        self.process.terminate()
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait()
        self.process.stderr.close()
        for fd in self.fds:
            os.close(fd)

    def new_object(self, interface):
        self.server_id += 1
        self.objects[self.server_id] = interface
        return self.server_id

    def event(self, obj, opcode, *values):
        payload = b""
        for value in values:
            if isinstance(value, str):
                string = value.encode() + b"\0"
                payload += U32.pack(len(string)) + string + b"\0" * (-len(string) % 4)
            else:
                payload += U32.pack(value & 0xFFFFFFFF)
        self.socket.sendall(HEADER.pack(obj, ((len(payload) + 8) << 16) | opcode) + payload)

    def receive(self):
        def fill(size):
            while len(self.data) < size:
                data, ancillary, _, _ = self.socket.recvmsg(65536, socket.CMSG_SPACE(64))
                if not data:
                    self.process.wait(timeout=5)
                    raise AssertionError("nimzo disconnected: " +
                                         self.process.stderr.read().decode())
                self.data.extend(data)
                for level, kind, payload in ancillary:
                    if level == socket.SOL_SOCKET and kind == socket.SCM_RIGHTS:
                        fds = array.array("i")
                        fds.frombytes(payload)
                        self.fds.extend(fds)

        fill(8)
        obj, header = HEADER.unpack_from(self.data)
        size, opcode = header >> 16, header & 0xFFFF
        fill(size)
        payload = bytes(self.data[8:size])
        del self.data[:size]
        interface = self.objects[obj]
        name, signature, child = self.signatures[interface][opcode]
        values = []
        offset = 0
        for kind in signature:
            if kind == "f":
                values.append(self.fds.pop(0))
                continue
            value, = struct.unpack_from("=i" if kind == "i" else "=I", payload, offset)
            offset += 4
            if kind == "s":
                length = value
                value = payload[offset:offset + length - 1].decode()
                offset += (length + 3) & ~3
            if kind == "n" and child:
                self.objects[value] = child
            values.append(value)
        assert offset == len(payload), (interface, name, values)
        request = (obj, name, values)
        self.requests.append(request)
        self.request_phases.append(self.phase)

        if interface == "wl_display" and name == "get_registry":
            globals = [
                ("river_window_manager_v1", 4), ("river_xkb_bindings_v1", 1),
                ("wl_compositor", 4), ("wl_shm", 1),
            ]
            if self.advertise_output_manager:
                globals.append(("zwlr_output_manager_v1", 4))
            if self.advertise_layer_shell:
                globals.append(("river_layer_shell_v1", 1))
            if self.ipc_enabled:
                self.logical_output_global_ids = [
                    len(globals) + index + 1
                    for index in range(len(self.logical_outputs))
                ]
                globals.extend(("wl_output", 4) for _ in self.logical_outputs)
            for index, (global_name, version) in enumerate(globals, 1):
                self.event(values[0], 0, index, global_name, version)
        elif interface == "wl_display" and name == "sync":
            if self.defer_roundtrip:
                self.deferred_syncs.append(values[0])
            else:
                self.event(values[0], 0, 1)  # wl_callback.done
                self.event(1, 1, values[0])  # wl_display.delete_id
        elif interface == "wl_registry" and name == "bind":
            global_name, bound_interface, _, new_id = values
            self.objects[new_id] = bound_interface
            if bound_interface == "wl_output":
                self.globals[f"wl_output:{global_name}"] = new_id
                output_index = self.logical_output_global_ids.index(global_name)
                self.event(new_id, 4, self.logical_output_names[output_index])
            else:
                self.globals[bound_interface] = new_id
        elif interface == "wl_shm" and name == "create_pool":
            _, fd, count = values
            try:
                assert os.fstat(fd).st_size >= count
                pixels = os.pread(fd, count, 0)
                assert len(pixels) == count
                assert all(pixel >> 24 == 255 for pixel, in struct.iter_unpack("=I", pixels))
                self.images.append(pixels)
                self.storage_checks += 1
            finally:
                os.close(fd)
        elif interface == "river_layer_shell_v1" and name == "get_output":
            child, parent = values
            assert parent not in self.layer_outputs, "only one layer object per output"
            self.layer_outputs[parent] = child
            self.pending_layer_events.append((child, 0, self.river_outputs[parent]["area"]))
        elif interface == "river_layer_shell_v1" and name == "get_seat":
            child, parent = values
            assert parent not in self.layer_seats, "only one layer object per seat"
            self.layer_seats[parent] = child
        elif interface == "river_layer_shell_output_v1" and name == "set_default":
            assert self.phase == "manage", "default output must be selected in a manage sequence"
        elif interface.startswith("zwlr_output_"):
            self.output_request(obj, interface, name, values)
        elif name == "get_xkb_binding":
            self.keybindings[tuple(values[2:])] = values[1]
        elif name == "get_pointer_binding":
            self.pointerbindings[tuple(values[1:])] = values[0]
        elif name == "destroy":
            if interface == "river_output_v1":
                assert obj not in self.layer_outputs, "destroy the layer output before its parent"
                self.river_outputs.pop(obj, None)
            if interface == "river_seat_v1":
                assert obj not in self.layer_seats, "destroy the layer seat before its parent"
            for objects in [self.layer_outputs, self.layer_seats]:
                for parent, child in list(objects.items()):
                    if child == obj:
                        del objects[parent]
            for bindings in [self.keybindings, self.pointerbindings]:
                for key, binding in list(bindings.items()):
                    if binding == obj:
                        del bindings[key]
            self.event(1, 1, obj)
        elif obj == getattr(self, "wm", None) and name == "manage_finish":
            self.phase = "await-render"
        elif obj == getattr(self, "wm", None) and name == "render_finish":
            self.phase = "idle"
        return request

    def add_logical_output(self, x=0, y=0, width=1280, height=720, area=None,
                            name=None):
        output = self.new_object("river_output_v1")
        self.river_outputs[output] = dict(bounds=(x, y, width, height),
                                          area=area or (x, y, width, height),
                                          name=name)
        self.event(self.wm, 7, output)
        if self.ipc_enabled:
            output_index = len(self.river_outputs) - 1
            if output_index < len(self.logical_output_global_ids):
                self.event(output, 1, self.logical_output_global_ids[output_index])
        self.event(output, 2, x, y)
        self.event(output, 3, width, height)
        return output

    def add_output(self, name, width=1920, height=1080, x=0, y=0, scale=256,
                   transform=0, enabled=1):
        head = self.new_object("zwlr_output_head_v1")
        mode = self.new_object("zwlr_output_mode_v1")
        self.output_heads[head] = dict(name=name, mode=mode, x=x, y=y,
                                       scale=scale, transform=transform,
                                       enabled=enabled, adaptive_sync=0)
        self.output_modes[mode] = (width, height, 60000)
        self.event(self.globals["zwlr_output_manager_v1"], 0, head)
        self.event(head, 0, name)
        self.event(head, 3, mode)
        self.event(mode, 0, width, height)
        self.event(mode, 1, 60000)
        self.event(mode, 2)
        self.output_state_events(head)
        return head

    def output_state_events(self, head):
        state = self.output_heads[head]
        self.event(head, 4, state["enabled"])
        if state["enabled"]:
            self.event(head, 5, state["mode"])
            self.event(head, 6, state["x"], state["y"])
            self.event(head, 7, state["transform"])
            self.event(head, 8, state["scale"])
        self.event(head, 13, state["adaptive_sync"])

    def outputs_done(self):
        self.output_serial += 1
        self.event(self.globals["zwlr_output_manager_v1"], 1, self.output_serial)

    def output_request(self, obj, interface, name, values):
        if name == "create_configuration":
            self.output_configurations[values[0]] = {}
        elif name == "enable_head":
            child, head = values
            self.output_configurations[obj][head] = dict(self.output_heads[head], enabled=1)
            self.output_config_heads[child] = (obj, head)
        elif name == "disable_head":
            self.output_configurations[obj][values[0]] = dict(self.output_heads[values[0]], enabled=0)
        elif interface == "zwlr_output_configuration_head_v1":
            configuration, head = self.output_config_heads[obj]
            state = self.output_configurations[configuration][head]
            if name == "set_position":
                state["x"], state["y"] = values
            elif name == "set_mode":
                state["mode"] = values[0]
            elif name == "set_custom_mode":
                self.output_modes[state["mode"]] = tuple(values)
            elif name in {"set_transform", "set_scale", "set_adaptive_sync"}:
                state[name[4:]] = values[0]
        elif name == "apply":
            planned = self.output_configurations[obj]
            assert set(planned) == set(self.output_heads), "every connected head must be included"
            self.output_applications.append({s["name"]: dict(s) for s in planned.values()})
            reply = self.output_replies.pop(0) if self.output_replies else 0
            self.event(obj, reply)  # succeeded/failed/cancelled
            if reply == 0:
                self.output_heads = {head: dict(state) for head, state in planned.items()}
                for head in self.output_heads:
                    self.output_state_events(head)
                self.outputs_done()
            elif reply == 2:
                self.outputs_done()  # A fresh snapshot after a serial race.
        elif name == "destroy":
            for child, (configuration, _) in list(self.output_config_heads.items()):
                if configuration == obj:
                    self.event(1, 1, child)
                    del self.output_config_heads[child]
            del self.output_configurations[obj]
            self.event(1, 1, obj)
        elif name == "release":
            self.event(1, 1, obj)

    def until(self, predicate):
        while not predicate():
            self.receive()

    def finish(self, name):
        start = len(self.requests)
        while True:
            obj, request, _ = self.receive()
            if obj == self.wm and request == name:
                return self.requests[start:]

    def cycle(self, dimensions=None):
        start = len(self.requests)
        for obj, opcode, values in self.pending_layer_events:
            self.event(obj, opcode, *values)
        self.pending_layer_events = []
        self.phase = "manage"
        self.event(self.wm, 2)  # manage_start
        requests = self.finish("manage_finish")
        if dimensions:
            self.event(self.window, 2, *dimensions)
        self.phase = "render"
        self.event(self.wm, 3)  # render_start
        requests += self.finish("render_finish")
        self.last_cycle_phases = self.request_phases[start:]
        return requests

    def map_window(self, title=None, app_id=None, decoration=3,
                   dimensions=(640, 480)):
        window = self.new_object("river_window_v1")
        self.window = window
        self.event(self.wm, 6, window)
        self.event(window, 6, decoration)  # decoration_hint
        if app_id is not None:
            self.event(window, 3, app_id)
        if title is not None:
            self.event(window, 4, title)
        return window, self.cycle(dimensions=dimensions)

    def key(self, keysym, modifiers):
        binding = self.keybindings[(keysym, modifiers)]
        self.event(binding, 0)  # pressed
        requests = self.cycle()
        self.last_key_phases = self.last_cycle_phases[:]
        # A reload destroys the binding before the physical key is released.
        if binding in self.keybindings.values():
            self.event(binding, 1)  # released
        self.cycle()
        return requests

    def pointer_binding(self, button, modifiers=64):
        return self.pointerbindings[(button, modifiers)]


class ProtocolTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="nimzo-test-")
        self.addCleanup(self.directory.cleanup)

    def start_server(self, **environment):
        server = TestServer.__new__(TestServer)
        self.addCleanup(lambda: server.close() if hasattr(server, "process") else None)
        server.__init__(self.directory.name, **environment)
        return server
    def wait_for_manage_dirty(self, server):
        start = len(server.requests)
        server.until(lambda: any(
            obj == server.wm and name == "manage_dirty"
            for obj, name, _ in server.requests[start:]))

    def ipc_command(self, server, client, text):
        ipc_send(client, IPC_COMMAND, text.encode())
        self.wait_for_manage_dirty(server)
        server.cycle()
        response_type, payload = ipc_receive(client)
        self.assertEqual(response_type, IPC_COMMAND)
        return json.loads(payload)

    def assert_command_success(self, result):
        self.assertEqual(result.get("success"), True, result)
        self.assertFalse(result.get("parse_error", False), result)

    def assert_command_failure(self, result, parse_error=False):
        self.assertEqual(result.get("success"), False, result)
        self.assertTrue(result.get("error"), result)
        self.assertEqual(result.get("parse_error", False), parse_error, result)


    def test_ipc_tree_and_subscriptions_follow_state(self):
        path = Path(self.directory.name) / "sway.sock"
        server = self.start_server(
            SWAYSOCK=str(path),
            initial_app_id="foot",
            initial_title="Terminal",
            configuration="""
bindsym Mod4+1 workspace number 1
bindsym Mod4+2 workspace number 2
""",
            logical_outputs=[dict(name="DP-1", width=1280, height=720)],
        )
        first_window_id = server.window
        first_client = connect_ipc(path)
        second_client = connect_ipc(path)
        self.addCleanup(first_client.close)
        self.addCleanup(second_client.close)

        tree = receive_tree(first_client)
        self.assertEqual([output["name"] for output in tree_outputs(tree)], ["DP-1"])
        output, workspace = find_workspace(tree, "1")
        self.assertEqual(workspace["output"], "DP-1")
        self.assertTrue(output["visible"])
        self.assertFalse(output["focused"])
        self.assertTrue(workspace["focused"])
        first = find_window(workspace, "Terminal")
        self.assertEqual(first["app_id"], "foot")
        self.assertTrue(first["focused"])
        self.assertTrue(first["visible"])
        self.assertEqual(first["type"], "floating_con")
        self.assertEqual(first["rect"]["width"], 640)
        self.assertEqual(first["rect"]["height"], 480)
        self.assertEqual(workspace["focus"][-1], first["id"])

        for client in (first_client, second_client):
            response_type, response = ipc_json(client, IPC_SUBSCRIBE, ["workspace"])
            self.assertEqual(response_type, IPC_SUBSCRIBE)
            self.assertEqual(response, {"success": True})
        response_type, response = ipc_json(first_client, IPC_SUBSCRIBE, ["window"])
        self.assertEqual(response_type, IPC_SUBSCRIBE)
        self.assertEqual(response, {"success": True})
        response_type, response = ipc_json(second_client, IPC_SUBSCRIBE, ["window"])
        self.assertEqual(response_type, IPC_SUBSCRIBE)
        self.assertEqual(response, {"success": True})
        # A repeated request is accepted and does not discard prior event types.
        response_type, response = ipc_json(first_client, IPC_SUBSCRIBE, ["workspace"])
        self.assertEqual(response_type, IPC_SUBSCRIBE)
        self.assertEqual(response, {"success": True})

        server.event(server.window, 4, "Renamed")
        server.cycle()
        self.assertEqual(ipc_event(first_client), {"change": "reload"})
        self.assertEqual(ipc_event(second_client), {"change": "reload"})
        tree = receive_tree(first_client)
        _, workspace = find_workspace(tree, "1")
        first = find_window(workspace, "Renamed")
        self.assertEqual(first["app_id"], "foot")

        server.key(0x32, 64)
        self.assertEqual(ipc_event(first_client), {"change": "reload"})
        self.assertEqual(ipc_event(second_client), {"change": "reload"})
        server.map_window(title="Browser", app_id="firefox")
        self.assertEqual(ipc_event(first_client), {"change": "reload"})
        self.assertEqual(ipc_event(second_client), {"change": "reload"})
        tree = receive_tree(first_client)
        _, workspace_two = find_workspace(tree, "2")
        self.assertTrue(workspace_two["focused"])
        browser = find_window(workspace_two, "Browser")
        self.assertEqual(browser["app_id"], "firefox")
        self.assertTrue(browser["focused"])
        _, workspace_one = find_workspace(tree, "1")
        self.assertFalse(workspace_one["focused"])
        self.assertFalse(find_window(workspace_one, "Renamed")["focused"])

        server.key(0x31, 64)
        self.assertEqual(ipc_event(first_client), {"change": "reload"})
        self.assertEqual(ipc_event(second_client), {"change": "reload"})
        server.event(first_window_id, 0)  # closed
        server.cycle()
        self.assertEqual(ipc_event(first_client), {"change": "reload"})
        self.assertEqual(ipc_event(second_client), {"change": "reload"})
        tree = receive_tree(first_client)
        _, workspace_one = find_workspace(tree, "1")
        self.assertFalse(any(window["name"] == "Renamed"
                             for window in workspace_one["floating_nodes"]))

    def test_ipc_partial_and_multiple_requests(self):
        path = Path(self.directory.name) / "sway.sock"
        self.start_server(SWAYSOCK=str(path),
                          logical_outputs=[dict(name="HDMI-A-1")])
        client = connect_ipc(path)
        self.addCleanup(client.close)
        frames = ipc_frame(IPC_GET_TREE) + ipc_frame(IPC_GET_TREE)
        client.sendall(frames[:7])
        client.sendall(frames[7:])
        first_type, first_payload = ipc_receive(client)
        second_type, second_payload = ipc_receive(client)
        self.assertEqual((first_type, second_type), (IPC_GET_TREE, IPC_GET_TREE))
        self.assertEqual(json.loads(first_payload), json.loads(second_payload))

    def test_ipc_commands_execute_and_keep_get_tree_coherent(self):
        path = Path(self.directory.name) / "sway.sock"
        server = self.start_server(SWAYSOCK=str(path),
                                   logical_outputs=[dict(name="DP-1")])
        client = connect_ipc(path)
        self.addCleanup(client.close)

        # Waybar's click form and an immediately pipelined GET_TREE must
        # observe one coherent manage/render result.
        client.sendall(
            ipc_frame(IPC_COMMAND, b"workspace --no-auto-back-and-forth number 2") +
            ipc_frame(IPC_GET_TREE)
        )
        self.wait_for_manage_dirty(server)
        server.cycle()
        response_type, payload = ipc_receive(client)
        self.assertEqual(response_type, IPC_COMMAND)
        response = json.loads(payload)
        self.assertEqual(len(response), 1)
        self.assert_command_success(response[0])
        response_type, payload = ipc_receive(client)
        self.assertEqual(response_type, IPC_GET_TREE)
        tree = json.loads(payload)
        _, workspace = find_workspace(tree, "2")
        self.assertTrue(workspace["focused"])

        response = self.ipc_command(
            server, client, 'workspace --no-auto-back-and-forth "alpha;beta"')
        self.assertEqual(len(response), 1)
        self.assert_command_success(response[0])
        tree = receive_tree(client)
        _, workspace = find_workspace(tree, "alpha;beta")
        self.assertTrue(workspace["focused"])

    def test_ipc_workspace_newlines_and_chains_preserve_order(self):
        path = Path(self.directory.name) / "sway.sock"
        server = self.start_server(
            SWAYSOCK=str(path), logical_outputs=[dict(name="DP-1")])
        client = connect_ipc(path)
        self.addCleanup(client.close)

        response = self.ipc_command(
            server, client,
            "workspace --no-auto-back-and-forth number 2\n"
            "workspace --no-auto-back-and-forth \"named\"")
        self.assertEqual(len(response), 2)
        for result in response:
            self.assert_command_success(result)
        tree = receive_tree(client)
        _, workspace = find_workspace(tree, "named")
        self.assertTrue(workspace["focused"])
        server.map_window(title="Named workspace window")

        response = self.ipc_command(
            server, client, "workspace number 3; workspace number 4")
        self.assertEqual(len(response), 2)
        for result in response:
            self.assert_command_success(result)
        tree = receive_tree(client)
        _, workspace = find_workspace(tree, "4")
        self.assertTrue(workspace["focused"])
        server.map_window(title="Numbered workspace window")

        # Waybar's scroll actions use the same IPC command endpoint.
        response = self.ipc_command(server, client, "workspace next")
        self.assertEqual(len(response), 1)
        self.assert_command_success(response[0])
        tree = receive_tree(client)
        _, workspace = find_workspace(tree, "named")
        self.assertTrue(workspace["focused"])

        response = self.ipc_command(server, client, "workspace prev")
        self.assertEqual(len(response), 1)
        self.assert_command_success(response[0])
        tree = receive_tree(client)
        _, workspace = find_workspace(tree, "4")
        self.assertTrue(workspace["focused"])

    def test_ipc_runtime_failures_are_not_parse_errors(self):
        path = Path(self.directory.name) / "sway.sock"
        server = self.start_server(
            SWAYSOCK=str(path),
            configuration="bindsym Ctrl+Alt+BackSpace exit\n",
            logical_outputs=[dict(name="DP-1")],
        )
        client = connect_ipc(path)
        self.addCleanup(client.close)

        # There is no output in this direction, so this is a valid command
        # whose runtime context rejects it.
        response = self.ipc_command(server, client, "focus output right")
        self.assertEqual(len(response), 1)
        self.assert_command_failure(response[0])
        self.assertFalse(response[0].get("parse_error", False))

        server.config_path.unlink()
        response = self.ipc_command(server, client, "reload")
        self.assertEqual(len(response), 1)
        self.assert_command_failure(response[0])
        self.assertFalse(response[0].get("parse_error", False))

        server.close()
        client.close()
        server = self.start_server(SWAYSOCK=str(path), layer_shell=True)
        client = connect_ipc(path)
        self.addCleanup(client.close)
        layer_seat = server.layer_seats[server.seat]
        server.event(layer_seat, 0)  # focus_exclusive
        server.cycle()
        response = self.ipc_command(server, client, "close")
        self.assertEqual(len(response), 1)
        self.assert_command_failure(response[0])
        self.assertFalse(response[0].get("parse_error", False))

        response = self.ipc_command(server, client, "unsupported-command")
        self.assertEqual(len(response), 1)
        self.assert_command_failure(response[0], parse_error=True)

    def test_ipc_partial_chain_executes_before_parse_failure(self):
        path = Path(self.directory.name) / "sway.sock"
        server = self.start_server(
            SWAYSOCK=str(path), logical_outputs=[dict(name="DP-1")])
        client = connect_ipc(path)
        self.addCleanup(client.close)

        response = self.ipc_command(
            server, client,
            "workspace --no-auto-back-and-forth number 2\n"
            "not-a-command\n"
            "workspace number 3")
        self.assertEqual(len(response), 2)
        self.assert_command_success(response[0])
        self.assert_command_failure(response[1], parse_error=True)
        tree = receive_tree(client)
        _, workspace = find_workspace(tree, "2")
        self.assertTrue(workspace["focused"])
        with self.assertRaises(AssertionError):
            find_workspace(tree, "3")

    def test_ipc_multiple_clients_keep_ordered_command_queues(self):
        path = Path(self.directory.name) / "sway.sock"
        server = self.start_server(
            SWAYSOCK=str(path), logical_outputs=[dict(name="DP-1")])
        first = connect_ipc(path)
        second = connect_ipc(path)
        self.addCleanup(first.close)
        self.addCleanup(second.close)

        ipc_send(first, IPC_COMMAND, b"workspace number 2")
        ipc_send(second, IPC_COMMAND, b"workspace number 3")
        self.wait_for_manage_dirty(server)
        server.cycle()
        response_type, payload = ipc_receive(first)
        self.assertEqual(response_type, IPC_COMMAND)
        first_response = json.loads(payload)
        response_type, payload = ipc_receive(second)
        self.assertEqual(response_type, IPC_COMMAND)
        second_response = json.loads(payload)
        self.assert_command_success(first_response[0])
        self.assert_command_success(second_response[0])

        # A client may submit another command only after its first reply;
        # another client's queue must not disturb that ordering.
        response = self.ipc_command(server, first, "workspace number 4")
        self.assert_command_success(response[0])
        tree = receive_tree(first)
        _, workspace = find_workspace(tree, "4")
        self.assertTrue(workspace["focused"])

    def test_ipc_disconnect_does_not_reuse_a_stale_command_reply(self):
        path = Path(self.directory.name) / "sway.sock"
        server = self.start_server(
            SWAYSOCK=str(path), logical_outputs=[dict(name="DP-1")])
        stale = connect_ipc(path)
        stale.sendall(ipc_frame(IPC_COMMAND, b"not-a-command"))
        stale.close()
        client = connect_ipc(path)
        self.addCleanup(client.close)
        response = self.ipc_command(server, client, "workspace number 2")
        self.assertEqual(len(response), 1)
        self.assert_command_success(response[0])
        self.assertFalse(response[0].get("parse_error", False))

    def test_ipc_exit_reply_precedes_exit_session(self):
        path = Path(self.directory.name) / "sway.sock"
        server = self.start_server(
            SWAYSOCK=str(path), logical_outputs=[dict(name="DP-1")])
        client = connect_ipc(path)
        self.addCleanup(client.close)
        ipc_send(client, IPC_COMMAND, b"exit")
        self.wait_for_manage_dirty(server)
        server.cycle()
        response_type, payload = ipc_receive(client)
        self.assertEqual(response_type, IPC_COMMAND)
        response = json.loads(payload)
        self.assertEqual(len(response), 1)
        self.assert_command_success(response[0])
        # The exit request is deferred until the command frame is flushed;
        # that flush schedules one final dirty manage sequence.
        server.finish("manage_dirty")
        requests = server.cycle()
        self.assertTrue(any(name == "exit_session" for _, name, _ in requests))

    def test_ipc_move_and_close_update_managed_state(self):
        path = Path(self.directory.name) / "sway.sock"
        server = self.start_server(
            SWAYSOCK=str(path), logical_outputs=[dict(name="DP-1")])
        client = connect_ipc(path)
        self.addCleanup(client.close)

        response = self.ipc_command(server, client, "move container to workspace number 2")
        self.assert_command_success(response[0])
        tree = receive_tree(client)
        _, workspace = find_workspace(tree, "2")
        self.assertEqual(len(workspace["floating_nodes"]), 1)
        _, workspace_one = find_workspace(tree, "1")
        self.assertEqual(workspace_one["floating_nodes"], [])
        self.assertTrue(workspace_one["focused"])
        response = self.ipc_command(server, client, "close")
        self.assert_command_failure(response[0])
        self.assertFalse(any(obj == server.window and name == "close"
                             for obj, name, _ in server.requests))
        response = self.ipc_command(server, client, "workspace number 2")
        self.assert_command_success(response[0])

        response = self.ipc_command(server, client, "close")
        self.assert_command_success(response[0])
        self.assertTrue(any(obj == server.window and name == "close"
                            for obj, name, _ in server.requests))
        for (_, name, _), phase in zip(server.requests, server.request_phases):
            if name in {"focus_window", "clear_focus", "close"}:
                self.assertEqual(phase, "manage")
        server.event(server.window, 0)  # The client acknowledges the close.
        server.cycle()
        tree = receive_tree(client)
        _, workspace = find_workspace(tree, "2")
        self.assertEqual(workspace["floating_nodes"], [])

    def test_ipc_path_collisions_and_opt_out_leave_paths_untouched(self):
        regular = Path(self.directory.name) / "regular"
        regular.write_bytes(b"do not replace")
        regular_inode = regular.stat().st_ino
        server = self.start_server(SWAYSOCK=str(regular))
        self.assertEqual(regular.stat().st_ino, regular_inode)
        self.assertEqual(regular.read_bytes(), b"do not replace")
        self.assertTrue(regular.exists())
        server.close()

        target = Path(self.directory.name) / "target"
        target.write_bytes(b"symlink target")
        link = Path(self.directory.name) / "link"
        link.symlink_to(target)
        link_inode = link.lstat().st_ino
        server = self.start_server(SWAYSOCK=str(link))
        self.assertTrue(link.is_symlink())
        self.assertEqual(link.lstat().st_ino, link_inode)
        self.assertEqual(target.read_bytes(), b"symlink target")
        server.close()

        occupied_path = Path(self.directory.name) / "occupied.sock"
        occupied = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        occupied.bind(str(occupied_path))
        occupied.listen(1)
        self.addCleanup(occupied.close)
        occupied_inode = occupied_path.stat().st_ino
        server = self.start_server(SWAYSOCK=str(occupied_path))
        self.assertTrue(occupied_path.exists())
        self.assertEqual(occupied_path.stat().st_ino, occupied_inode)
        server.close()

        sockets_before = set(Path(self.directory.name).glob("*.sock"))
        self.start_server(SWAYSOCK="", logical_outputs=[dict(name="DP-2")])
        self.assertEqual(set(Path(self.directory.name).glob("*.sock")), sockets_before)

    def test_ipc_socket_cleanup_preserves_replacement_paths(self):
        path = Path(self.directory.name) / "cleanup.sock"
        server = self.start_server(SWAYSOCK=str(path))
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        server.close()
        self.assertFalse(path.exists())

        server = self.start_server(SWAYSOCK=str(path))
        path.unlink()
        path.write_text("replacement")
        inode = path.stat().st_ino
        server.close()
        self.assertEqual(path.stat().st_ino, inode)
        self.assertEqual(path.read_text(), "replacement")

    def test_ipc_bursts_and_malformed_clients_leave_other_clients_usable(self):
        path = Path(self.directory.name) / "burst.sock"
        self.start_server(SWAYSOCK=str(path))
        client = connect_ipc(path)
        self.addCleanup(client.close)
        client.sendall(ipc_frame(IPC_GET_TREE) * 130)
        for _ in range(130):
            response_type, response = ipc_receive(client)
            self.assertEqual(response_type, IPC_GET_TREE)
            self.assertEqual(json.loads(response)["type"], "root")
        for data in (b"bad-ip" + IPC_HEADER.pack(0, IPC_GET_TREE),
                     IPC_MAGIC + IPC_HEADER.pack(2 ** 32 - 1, IPC_GET_TREE)):
            malformed = connect_ipc(path)
            try:
                malformed.sendall(data)
                self.assertEqual(malformed.recv(1), b"")
            finally:
                malformed.close()
        self.assertEqual(receive_tree(client)["type"], "root")

    def test_ipc_stalled_clients_do_not_block_wayland_input_or_other_clients(self):
        path = Path(self.directory.name) / "sway.sock"
        server = self.start_server(
            SWAYSOCK=str(path),
            configuration="bindsym Alt+x exec foot\n",
        )
        client = connect_ipc(path)
        self.addCleanup(client.close)
        client.sendall(IPC_MAGIC[:4])
        slow = connect_ipc(path)
        self.addCleanup(slow.close)
        slow.sendall(ipc_frame(IPC_GET_TREE) * 5000)
        server.key(0x78, 8)
        deadline = time.monotonic() + 5
        while not server.marker.exists() and time.monotonic() < deadline:
            time.sleep(0.01)
        self.assertEqual(server.marker.read_text(), "spawned\n")
        healthy = connect_ipc(path)
        self.addCleanup(healthy.close)
        self.assertEqual(receive_tree(healthy)["type"], "root")

    def test_window_and_seat_events_during_initial_roundtrip(self):
        server = self.start_server(defer_roundtrip=True)
        self.assertEqual(server.storage_checks, 1)
        self.assertEqual(len(server.keybindings), 7)
        self.assertTrue(any(name == "exit_session" for _, name, _ in server.key(0xFF08, 12)))

    def test_decorations_and_input_survive_rendering(self):
        server = self.start_server()
        self.assertEqual(server.storage_checks, 1)
        self.assertTrue(any(name == "set_borders" and values ==
                            [15, 2, 0x8B8B8B8B, 0, 0, 0xFFFFFFFF]
                            for _, name, values in server.requests))
        self.assertTrue(any(name == "set_position" and values == [2, 26]
                            for _, name, values in server.requests))

        # Releasing a buffer must not cause a same-size titlebar to be redrawn.
        buffer = next(values[0] for _, name, values in server.requests
                      if name == "create_buffer")
        server.event(buffer, 0)
        server.cycle()
        self.assertEqual(server.storage_checks, 1)

        server.event(server.window, 4, "A visible title")
        server.cycle()
        self.assertEqual(server.storage_checks, 2)

        # Both terminal bindings still work after rendering text in a decoration.
        for keysym, modifiers in [(0x20, 64), (0x78, 8)]:
            server.key(keysym, modifiers)
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if server.marker.exists() and len(server.marker.read_text().splitlines()) == 2:
                break
            time.sleep(0.01)
        self.assertEqual(len(server.marker.read_text().splitlines()), 2)
        self.assertTrue(any(name == "close" for _, name, _ in server.key(0x71, 64)))

        # Super+left drag: op deltas still update window position.
        server.event(server.seat, 2, server.window)  # pointer_enter
        server.event(server.pointer_binding(0x110), 0)
        self.assertTrue(any(name == "op_start_pointer" for _, name, _ in server.cycle()))
        server.event(server.seat, 6, 30, 40)  # op_delta
        self.assertTrue(any(name == "set_position" and values == [32, 66]
                            for _, name, values in server.cycle()))
        server.event(server.seat, 7)  # op_release
        self.assertTrue(any(name == "op_end" for _, name, _ in server.cycle()))

        # Super+right resize, including a new titlebar buffer at the new width.
        server.event(server.pointer_binding(0x111), 0)
        server.cycle()
        server.event(server.seat, 6, 20, 10)
        self.assertTrue(any(name == "propose_dimensions" and values == [660, 490]
                            for _, name, values in server.cycle(dimensions=(660, 490))))
        self.assertEqual(server.storage_checks, 3)
        server.event(server.seat, 7)
        server.cycle()

        # Switching to CSD detaches the titlebar; switching back uses the latest title.
        before_detach = server.images[-1]
        server.event(server.window, 6, 0)
        self.assertTrue(any(name == "attach" and values == [0, 0, 0]
                            for _, name, values in server.cycle()))
        server.event(server.window, 4, "Title changed while using CSD")
        server.cycle()
        self.assertEqual(server.storage_checks, 3)
        server.event(server.window, 6, 3)
        server.cycle()
        self.assertEqual(server.storage_checks, 4)
        self.assertNotEqual(server.images[-1], before_detach)
        self.assertIsNone(server.process.poll())
        self.assertTrue(any(name == "exit_session" for _, name, _ in server.key(0xFF08, 12)))

        # Closing a window must destroy its decoration and its base surface.
        server.event(server.window, 0)
        destroyed = [server.objects[obj] for obj, name, _ in server.cycle()
                     if name == "destroy"]
        self.assertIn("river_decoration_v1", destroyed)
        self.assertIn("wl_surface", destroyed)
        self.assertTrue(any(name == "exit_session" for _, name, _ in server.key(0xFF1B, 64)))

    def test_title_rendering_and_updates(self):
        server = self.start_server(initial_title="A visible title")
        initial_image = server.images[-1]
        colors = {pixel for pixel, in struct.iter_unpack("=I", initial_image)}
        self.assertIn(0xFFFFFFFF, colors)  # White text, not just a red rectangle.
        self.assertIn(0xFF8B0000, colors)

        # An unchanged title must not allocate another buffer.
        server.event(server.window, 4, "A visible title")
        server.cycle()
        self.assertEqual(server.storage_checks, 1)

        # UTF-8 titles, including newlines, update without a width change.
        server.event(server.window, 4, "Café — 日本語\nA second line")
        server.cycle()
        self.assertEqual(server.storage_checks, 2)
        self.assertNotEqual(server.images[-1], initial_image)

        # Empty and nullable titles erase the old text rather than leaving it.
        background = struct.pack("=I", 0xFF8B0000)
        server.event(server.window, 4, "")
        server.cycle()
        self.assertEqual(server.images[-1], background * (640 * 24))
        server.event(server.window, 4, "Another title")
        server.cycle()
        server.event(server.window, 4, 0)  # Null string.
        server.cycle()
        self.assertEqual(server.images[-1], background * (640 * 24))

        # Long titles are constrained to the titlebar's padded text area.
        server.event(server.window, 4, "A long window title " * 100)
        server.cycle(dimensions=(80, 480))
        image = server.images[-1]
        self.assertNotEqual(image, background * (80 * 24))
        for y in range(24):
            row = image[y * 80 * 4:(y + 1) * 80 * 4]
            self.assertEqual(row[:8 * 4], background * 8)
            self.assertEqual(row[-8 * 4:], background * 8)

        # Extremely narrow windows don't trigger invalid layout widths/crashes.
        server.cycle(dimensions=(1, 480))
        self.assertEqual(server.images[-1], background * 24)
        server.cycle(dimensions=(640, 480))
        self.assertNotEqual(server.images[-1], background * (640 * 24))
        self.assertIsNone(server.process.poll())

    def test_workspace_switch_hides_old_window_and_restores_focus(self):
        server = self.start_server(configuration="""
bindsym Mod4+1 workspace number 1
bindsym Mod4+2 workspace number 2
""")
        first = server.window
        requests = server.key(0x32, 64)
        hidden = [index for index, (obj, name, _) in enumerate(requests)
                  if obj == first and name == "hide"]
        self.assertTrue(hidden)
        self.assertTrue(all(server.last_key_phases[index] == "render" for index in hidden))

        second, _ = server.map_window()
        requests = server.key(0x31, 64)
        self.assertTrue(any(obj == second and name == "hide"
                            for obj, name, _ in requests))
        self.assertTrue(any(obj == first and name == "show"
                            for obj, name, _ in requests))
        self.assertTrue(any(name == "focus_window" and values == [first]
                            for _, name, values in requests))
        self.assertTrue(all(server.last_key_phases[index] == "render"
                            for index, (_, name, _) in enumerate(requests)
                            if name in {"hide", "show"}))

    def test_move_container_does_not_follow_but_command_chain_does(self):
        server = self.start_server(configuration="""
bindsym Mod4+2 workspace number 2
bindsym Mod4+3 workspace number 3
bindsym Mod4+Shift+2 move container to workspace number 2
bindsym Mod4+Shift+3 move container to workspace number 3; workspace number 3
""")
        window = server.window
        server.key(0x32, 65)  # move container to workspace 2
        requests = server.key(0x32, 64)
        self.assertTrue(any(obj == window and name == "show"
                            for obj, name, _ in requests))
        self.assertTrue(any(name == "focus_window" and values == [window]
                            for _, name, values in requests))

        requests = server.key(0x33, 65)
        self.assertTrue(any(name == "focus_window" and values == [window]
                            for _, name, values in requests))
        self.assertFalse(any(obj == window and name == "hide"
                             for obj, name, _ in requests))

    def test_prev_next_cycles_numeric_then_named_workspaces(self):
        server = self.start_server(configuration="""
bindsym Mod4+2 workspace number 2
bindsym Mod4+4 workspace number 4
bindsym Mod4+a workspace "alpha"
bindsym Mod4+n workspace next
bindsym Mod4+p workspace prev
""")
        first = server.window
        server.key(0x32, 64)
        second, _ = server.map_window()
        server.key(0x34, 64)
        fourth, _ = server.map_window()
        server.key(0x61, 64)
        named, _ = server.map_window()

        for keysym, expected in [(0x31, first), (0x32, second), (0x34, fourth), (0x61, named)]:
            requests = server.key(0x6E, 64)
            self.assertTrue(any(name == "focus_window" and values == [expected]
                                for _, name, values in requests))
        requests = server.key(0x70, 64)
        self.assertTrue(any(name == "focus_window" and values == [fourth]
                            for _, name, values in requests))

    def test_focus_output_switches_the_visible_workspace(self):
        server = self.start_server(configuration="""
bindsym Mod4+o focus output right
bindsym Mod4+i focus output left
""", logical_outputs=[
            dict(x=0, width=640, height=480),
            dict(x=640, width=640, height=480),
        ])
        first = server.window
        server.key(0x6F, 64)
        second, _ = server.map_window()

        requests = server.key(0x69, 64)
        self.assertFalse(any(obj in {first, second} and name in {"hide", "show"}
                             for obj, name, _ in requests))
        self.assertTrue(any(name == "focus_window" and values == [first]
                            for _, name, values in requests))
        requests = server.key(0x6F, 64)
        self.assertFalse(any(obj in {first, second} and name in {"hide", "show"}
                             for obj, name, _ in requests))
        self.assertTrue(any(name == "focus_window" and values == [second]
                            for _, name, values in requests))

    def test_focus_output_prev_cycles_wraps_and_skips_removed_outputs(self):
        server = self.start_server(configuration="""
bindsym Mod4+o focus output right
bindsym Mod4+p focus output prev
""", logical_outputs=[
            dict(x=0, width=640, height=480),
            dict(x=640, width=640, height=480),
            dict(x=1280, width=640, height=480),
        ])
        first = server.window
        server.key(0x6F, 64)
        second, _ = server.map_window()
        server.key(0x6F, 64)
        third, _ = server.map_window()

        for target in [second, first, third]:
            requests = server.key(0x70, 64)
            self.assertTrue(any(name == "focus_window" and values == [target]
                                for _, name, values in requests))
            self.assertFalse(any(name in {"hide", "show"}
                                 for _, name, _ in requests))

        outputs = list(server.river_outputs)
        server.event(outputs[1], 0)  # Remove the middle output.
        server.cycle()
        requests = server.key(0x70, 64)
        self.assertTrue(any(name == "focus_window" and values == [first]
                            for _, name, values in requests))
        server.event(outputs[2], 0)  # Only the first output remains.
        server.cycle()
        requests = server.key(0x70, 64)
        self.assertFalse(any(name in {"clear_focus", "focus_window"}
                             for _, name, _ in requests))

    def test_focus_output_prev_without_outputs_preserves_window_focus(self):
        server = self.start_server(configuration="""
bindsym Mod4+p focus output prev
bindsym Mod4+q kill
""")
        requests = server.key(0x70, 64)
        self.assertFalse(any(name in {"clear_focus", "focus_window"}
                             for _, name, _ in requests))
        requests = server.key(0x71, 64)
        self.assertTrue(any(obj == server.window and name == "close"
                            for obj, name, _ in requests))

    def test_move_container_to_output_does_not_follow(self):
        server = self.start_server(configuration="""
bindsym Mod4+o focus output right
bindsym Mod4+Shift+o move container to output right
""", logical_outputs=[
            dict(x=0, width=640, height=480),
            dict(x=640, width=640, height=480),
        ])
        window = server.window
        node = next(values[0] for obj, name, values in server.requests
                    if obj == window and name == "get_node")
        original_position = next(values for obj, name, values in reversed(server.requests)
                                 if obj == node and name == "set_position")
        requests = server.key(0x6F, 65)
        self.assertTrue(any(obj == node and name == "set_position" and
                            values == [original_position[0] + 640, original_position[1]]
                            for obj, name, values in requests))
        self.assertTrue(any(obj == server.seat and name == "clear_focus"
                            for obj, name, _ in requests))
        requests = server.key(0x6F, 64)
        self.assertFalse(any(obj == window and name == "show"
                             for obj, name, _ in requests))
        self.assertTrue(any(name == "focus_window" and values == [window]
                            for _, name, values in requests))

    def test_move_workspace_to_output_follows_and_replaces_source(self):
        server = self.start_server(configuration="""
bindsym Mod4+o focus output right
bindsym Mod4+i focus output left
bindsym Mod4+2 workspace number 2
bindsym Mod4+Shift+o move workspace to output right
""", logical_outputs=[
            dict(x=0, width=640, height=480),
            dict(x=640, width=640, height=480),
        ])
        first = server.window
        server.key(0x6F, 64)
        second, _ = server.map_window()
        server.key(0x69, 64)
        node = next(values[0] for obj, name, values in server.requests
                    if obj == first and name == "get_node")
        original_position = next(values for obj, name, values in reversed(server.requests)
                                 if obj == node and name == "set_position")

        requests = server.key(0x6F, 65)
        self.assertTrue(any(obj == second and name == "hide"
                            for obj, name, _ in requests))
        self.assertTrue(any(obj == node and name == "set_position" and
                            values == [original_position[0] + 640, original_position[1]]
                            for obj, name, values in requests))
        self.assertFalse(any(name == "focus_window" and values == [first]
                             for _, name, values in requests))
        requests = server.key(0x69, 64)
        self.assertTrue(any(obj == server.seat and name == "clear_focus"
                            for obj, name, _ in requests))
        requests = server.key(0x32, 64)
        self.assertTrue(any(obj == second and name == "show"
                            for obj, name, _ in requests))
        self.assertTrue(any(name == "focus_window" and values == [second]
                            for _, name, values in requests))

    def test_output_removal_preserves_workspace_windows(self):
        server = self.start_server(configuration="""
bindsym Mod4+o focus output right
bindsym Mod4+2 workspace number 2
""", logical_outputs=[
            dict(x=0, width=640, height=480),
            dict(x=640, width=640, height=480),
        ])
        server.key(0x6F, 64)
        second, _ = server.map_window()
        output = list(server.river_outputs)[1]
        server.event(output, 0)  # removed
        server.cycle()

        requests = server.key(0x32, 64)
        self.assertTrue(any(obj == second and name == "show"
                            for obj, name, _ in requests))
        self.assertTrue(any(name == "focus_window" and values == [second]
                            for _, name, values in requests))

    def test_layer_shell_opt_in_reserved_area_and_output_lifetimes(self):
        server = self.start_server(layer_shell=True, defer_roundtrip=True, logical_outputs=[
            dict(area=(0, 32, 1280, 688)),
            dict(x=1280, area=(1280, 40, 1280, 680)),
        ])
        primary, secondary = server.river_outputs
        self.assertIn("river_layer_shell_v1", server.globals)
        self.assertEqual(len(server.layer_outputs), 2)
        self.assertEqual(len(server.layer_seats), 1)
        requests = server.cycle()
        self.assertTrue(any(name == "set_position" and values == [2, 58]
                            for _, name, values in requests))
        self.assertEqual(sum(name == "set_default" for _, name, _ in server.requests), 1)

        # Moving/removing an output must place windows in a remaining work area.
        primary_layer = server.layer_outputs[primary]
        secondary_layer = server.layer_outputs[secondary]
        server.event(primary, 0)  # removed
        requests = server.cycle()
        self.assertTrue(any(obj == primary_layer and name == "destroy"
                            for obj, name, _ in requests))
        self.assertTrue(any(obj == secondary_layer and name == "set_default"
                            for obj, name, _ in requests))
        self.assertTrue(any(name == "set_position" and values == [1282, 66]
                            for _, name, values in requests))
        self.assertEqual(len(server.layer_outputs), 1)
        layer_seat = server.layer_seats[server.seat]
        server.event(server.seat, 0)
        requests = server.cycle()
        self.assertTrue(any(obj == layer_seat and name == "destroy" for obj, name, _ in requests))
        self.assertEqual(len(server.layer_seats), 0)

    def test_layer_shell_placement_uses_pointer_output_and_its_panel(self):
        server = self.start_server(layer_shell=True, logical_outputs=[
            dict(area=(0, 24, 1280, 696)),
            dict(x=1280, area=(1280, 48, 1280, 672)),
        ])
        server.cycle()
        server.event(server.seat, 8, 1500, 200)  # pointer_position
        server.window = server.new_object("river_window_v1")
        server.event(server.wm, 6, server.window)
        server.event(server.window, 6, 3)
        requests = server.cycle(dimensions=(640, 480))
        self.assertTrue(any(name == "set_position" and values == [1282, 74]
                            for _, name, values in requests))
        # Reload must not create duplicate layer objects or restart startup apps.
        self.assertEqual(sum(name == "get_output" for _, name, _ in server.requests), 2)

    def test_layer_shell_decoration_changes_keep_titlebars_below_panels(self):
        server = self.start_server(layer_shell=True, logical_outputs=[dict(area=(0, 30, 1280, 690))])
        server.cycle()
        server.window = server.new_object("river_window_v1")
        server.event(server.wm, 6, server.window)
        server.event(server.window, 6, 0)  # Client-side decorations only.
        requests = server.cycle(dimensions=(640, 480))
        self.assertTrue(any(name == "set_position" and values == [2, 32]
                            for _, name, values in requests))
        server.event(server.window, 6, 3)  # Server-side titlebar becomes possible.
        requests = server.cycle()
        self.assertTrue(any(name == "set_position" and values == [2, 56]
                            for _, name, values in requests))

    def test_layer_shell_exclusive_focus_and_restore(self):
        server = self.start_server(layer_shell=True, configuration="""
client.focused #8b0000 #8b0000 #ffffff
client.unfocused #202020 #202020 #aaaaaa
bindsym Mod4+q kill
bindsym Mod4+n focus next
bindsym Ctrl+Alt+BackSpace exit
""")
        layer_seat = server.layer_seats[server.seat]
        first_window = server.window
        server.event(layer_seat, 0)  # focus_exclusive
        requests = server.cycle()
        self.assertFalse(any(name == "focus_window" for _, name, _ in requests))
        self.assertEqual(server.images[-1][:4], struct.pack("=I", 0xFF202020))
        self.assertFalse(any(name == "close" for _, name, _ in server.key(0x71, 64)))
        self.assertFalse(any(name == "focus_window" for _, name, _ in server.key(0x6E, 64)))
        server.event(server.seat, 2, first_window)
        server.event(server.pointer_binding(0x110), 0)
        self.assertFalse(any(name == "op_start_pointer" for _, name, _ in server.cycle()))

        # A new window while a launcher owns focus must not replace remembered focus.
        server.window = server.new_object("river_window_v1")
        server.event(server.wm, 6, server.window)
        server.event(server.window, 6, 3)
        server.cycle(dimensions=(640, 480))
        server.event(layer_seat, 2)  # focus_none
        requests = server.cycle()
        self.assertTrue(any(name == "focus_window" and values == [first_window]
                            for _, name, values in requests))
        self.assertTrue(any(name == "exit_session" for _, name, _ in server.key(0xFF08, 12)))

    def test_layer_shell_on_demand_focus_allows_return_to_same_window(self):
        server = self.start_server(layer_shell=True)
        layer_seat = server.layer_seats[server.seat]
        server.event(layer_seat, 1)  # focus_non_exclusive
        self.assertFalse(any(name == "focus_window" for _, name, _ in server.cycle()))
        server.event(server.seat, 4, server.window)  # window_interaction
        requests = server.cycle()
        self.assertTrue(any(name == "focus_window" and values == [server.window]
                            for _, name, values in requests))
        server.event(layer_seat, 2)
        self.assertFalse(any(name == "focus_window" for _, name, _ in server.cycle()))

    def test_exec_children_can_wait_for_their_own_children(self):
        marker = Path(self.directory.name) / "child-wait"
        program = (
            "import pathlib, signal, subprocess; "
            "assert signal.getsignal(signal.SIGCHLD) == signal.SIG_DFL; "
            "result = subprocess.run(['/bin/sh', '-c', 'exit 23']); "
            f"pathlib.Path({str(marker)!r}).write_text(str(result.returncode))"
        )
        command = shlex.join([sys.executable, "-c", program])
        self.start_server(configuration="exec " + command + "\n")
        deadline = time.monotonic() + 5
        while not marker.exists() and time.monotonic() < deadline:
            time.sleep(0.01)
        self.assertEqual(marker.read_text(), "23")

    def test_configuration_reload_recovers_invalid_lines(self):
        startup_marker = Path(self.directory.name) / "startup"
        initial = """
font pango:Sans 10
client.focused #123456 #101010 #ffffff
bindsym Alt+x exec foot
unsupported-startup-directive
bindsym Mod4+Shift+r reload
bindsym Ctrl+Alt+BackSpace exit
exec 'printf x >> "$TEST_STARTUP_MARKER"'
"""
        server = self.start_server(configuration=initial, initial_title="Configured title",
                                   TEST_STARTUP_MARKER=str(startup_marker))
        self.assertEqual(server.images[-1][:4], struct.pack("=I", 0xFF101010))
        self.assertIn((0x78, 8), server.keybindings)
        self.assertNotIn((0x20, 64), server.keybindings)  # No implicit keyboard bindings.
        self.assertTrue(any(name == "set_borders" and values ==
                            [15, 2, 0x12121212, 0x34343434, 0x56565656, 0xFFFFFFFF]
                            for _, name, values in server.requests))
        deadline = time.monotonic() + 5
        while not startup_marker.exists() and time.monotonic() < deadline:
            time.sleep(0.01)
        self.assertEqual(startup_marker.read_text(), "x")
        server.key(0x78, 8)
        deadline = time.monotonic() + 5
        while not server.marker.exists() and time.monotonic() < deadline:
            time.sleep(0.01)
        self.assertEqual(server.marker.read_text(), "spawned\n")

        replacement = """
font pango:monospace 14
floating_modifier Alt
client.focused #112233 #001122 #ffff00
bindsym Alt+Return exec foot
bindsym Mod4+Shift+r reload
bindsym Ctrl+Alt+BackSpace exit
exec 'printf x >> "$TEST_STARTUP_MARKER"'
"""
        server.config_path.write_text(replacement)
        requests = server.key(0x72, 65)
        self.assertTrue(any(name == "destroy" for _, name, _ in requests))
        self.assertNotIn((0x78, 8), server.keybindings)
        self.assertIn((0xFF0D, 8), server.keybindings)
        self.assertIn((0x110, 8), server.pointerbindings)
        self.assertNotIn((0x110, 64), server.pointerbindings)
        self.assertEqual(server.images[-1][:4], struct.pack("=I", 0xFF001122))
        colors = {pixel for pixel, in struct.iter_unpack("=I", server.images[-1])}
        self.assertIn(0xFFFFFF00, colors)  # Configured yellow text.
        server.key(0xFF0D, 8)
        deadline = time.monotonic() + 5
        while server.marker.read_text() != "spawned\nspawned\n" and time.monotonic() < deadline:
            time.sleep(0.01)
        self.assertEqual(server.marker.read_text(), "spawned\nspawned\n")
        server.event(server.seat, 2, server.window)
        server.event(server.pointer_binding(0x110, 8), 0)
        self.assertTrue(any(name == "op_start_pointer" for _, name, _ in server.cycle()))
        server.event(server.seat, 7)
        server.cycle()

        replacement_with_invalid_duplicate = replacement.replace(
            "bindsym Mod4+Shift+r reload\n",
            "bindsym Alt+x exec foot\n"
            "bindsym Alt+x unsupported-command\n"
            "bindsym Mod4+Shift+r reload\n"
        )
        server.config_path.write_text(replacement_with_invalid_duplicate)
        requests = server.key(0x72, 65)
        self.assertTrue(any(name == "destroy" for _, name, _ in requests))
        self.assertIn((0x78, 8), server.keybindings)
        self.assertIn((0xFF0D, 8), server.keybindings)
        marker_before = server.marker.read_text()
        server.key(0x78, 8)
        deadline = time.monotonic() + 5
        while server.marker.read_text() == marker_before and time.monotonic() < deadline:
            time.sleep(0.01)
        self.assertEqual(server.marker.read_text(), marker_before + "spawned\n")

        current_bindings = server.keybindings.copy()
        server.config_path.unlink()
        requests = server.key(0x72, 65)
        self.assertFalse(any(name == "destroy" for _, name, _ in requests))
        self.assertEqual(server.keybindings, current_bindings)
        self.assertTrue(any(name == "exit_session" for _, name, _ in server.key(0xFF08, 12)))
        time.sleep(0.05)
        self.assertEqual(startup_marker.read_text(), "x")  # Startup exec isn't rerun.

    def test_focused_and_unfocused_colors_follow_focus(self):
        server = self.start_server(configuration="""
client.focused #112233 #101010 #ffffff
client.unfocused #445566 #202020 #aaaaaa
bindsym Mod4+n focus next
""")
        first = server.window
        server.window = server.new_object("river_window_v1")
        server.event(server.wm, 6, server.window)
        server.event(server.window, 6, 3)
        server.cycle(dimensions=(640, 480))
        self.assertEqual({image[:4] for image in server.images[-2:]},
                         {struct.pack("=I", 0xFF101010), struct.pack("=I", 0xFF202020)})
        requests = server.key(0x6E, 64)
        self.assertTrue(any(name == "focus_window" and values == [first]
                            for _, name, values in requests))
        self.assertEqual(sum(name == "set_borders" for _, name, _ in requests), 2)

    def test_validate_does_not_require_a_wayland_server(self):
        path = Path(self.directory.name) / "config"
        path.write_text("set $term ghostty\nbindsym Alt+x exec $term\n")
        arguments = [str(ROOT / "nimzo"), "--validate", "-c", str(path)]
        valid = subprocess.run(arguments, capture_output=True, text=True, timeout=5)
        self.assertEqual(valid.returncode, 0, valid.stderr)
        path.write_text("# comment\noutput DP-3 {\n")
        warned = subprocess.run(arguments, capture_output=True, text=True, timeout=5)
        self.assertEqual(warned.returncode, 0, warned.stderr)
        self.assertIn(f"warning: {path}:2:", warned.stderr)

    def test_relative_outputs_apply_once_and_reload(self):
        configuration = """
output A position 10 20
output B position below A gap 1
bindsym Mod4+Shift+r reload
bindsym Ctrl+Alt+BackSpace exit
"""
        server = self.start_server(configuration=configuration, output_heads=[
            dict(name="A", width=2560, height=1440), dict(name="B"),
            dict(name="unconfigured", x=5000)])
        for _ in range(2):
            server.cycle()
        self.assertEqual(len(server.output_applications), 1)
        planned = server.output_applications[-1]
        self.assertEqual((planned["B"]["x"], planned["B"]["y"]), (10, 1461))
        self.assertEqual(planned["unconfigured"]["x"], 5000)
        server.config_path.write_text(configuration.replace("below A gap 1", "right-of A"))
        server.key(0x72, 65)
        server.cycle()
        self.assertEqual(len(server.output_applications), 2)
        self.assertEqual(server.output_applications[-1]["B"]["x"], 2570)
        self.assertTrue(any(name == "exit_session" for _, name, _ in server.key(0xFF08, 12)))

    def test_relative_outputs_follow_scale_rotation_and_hotplug(self):
        server = self.start_server(configuration="output B position right-of A",
                                   output_heads=[dict(name="A", width=2560, height=1440), dict(name="B")])
        server.cycle()
        a = next(head for head, state in server.output_heads.items() if state["name"] == "A")
        server.output_heads[a].update(scale=512, transform=1)
        server.output_state_events(a)
        server.outputs_done()
        server.cycle()
        server.cycle()
        self.assertEqual(server.output_applications[-1]["B"]["x"], 720)
        count = len(server.output_applications)
        mode = server.output_heads[a]["mode"]
        server.event(mode, 3)
        server.event(a, 9)
        del server.output_heads[a]
        server.outputs_done()
        server.cycle()
        self.assertEqual(len(server.output_applications), count)  # Missing anchor: keep layout.
        server.add_output("A", width=1000, height=900)
        server.outputs_done()
        server.cycle()
        server.cycle()
        self.assertEqual(server.output_applications[-1]["B"]["x"], 1000)
        self.assertIsNone(server.process.poll())

    def test_output_rules_without_manager_keep_input(self):
        server = self.start_server(configuration="""
output B position below A
bindsym Ctrl+Alt+BackSpace exit
""")
        self.assertEqual(len(server.output_applications), 0)
        self.assertEqual(server.storage_checks, 1)
        self.assertTrue(any(name == "exit_session" for _, name, _ in server.key(0xFF08, 12)))

    def test_new_mode_retries_without_a_geometry_change(self):
        server = self.start_server(configuration="""
output A resolution 2560x1440
output B position below A
bindsym Ctrl+Alt+BackSpace exit
""", output_heads=[dict(name="A"), dict(name="B")])
        server.cycle()
        self.assertEqual(len(server.output_applications), 0)  # Mode isn't advertised yet.
        a = next(head for head, state in server.output_heads.items() if state["name"] == "A")
        mode = server.new_object("zwlr_output_mode_v1")
        server.output_modes[mode] = (2560, 1440, 60000)
        server.event(a, 3, mode)
        server.event(mode, 0, 2560, 1440)
        server.event(mode, 1, 60000)
        server.event(mode, 2)
        server.outputs_done()
        server.cycle()
        server.cycle()
        self.assertEqual(len(server.output_applications), 1)
        self.assertEqual(server.output_applications[-1]["B"]["y"], 1440)

    def test_output_failure_keeps_input_and_cancellation_retries(self):
        configuration = "output B position below A\nbindsym Mod4+Shift+r reload\nbindsym Ctrl+Alt+BackSpace exit"
        server = self.start_server(configuration=configuration,
                                   output_heads=[dict(name="A"), dict(name="B")])
        server.cycle()
        server.output_replies = [1]
        server.config_path.write_text(configuration.replace("below A", "right-of A"))
        server.key(0x72, 65)
        server.cycle()
        count = len(server.output_applications)
        server.cycle()
        self.assertEqual(len(server.output_applications), count)  # No failed-apply busy loop.
        self.assertTrue(any(name == "exit_session" for _, name, _ in server.key(0xFF08, 12)))
        server.output_replies = [2, 0]
        server.key(0x72, 65)
        server.cycle()
        server.cycle()
        self.assertEqual(len(server.output_applications), count + 2)
        self.assertEqual(server.output_applications[-1]["B"]["x"], 1920)

    def test_default_config_path_falls_back_to_home(self):
        path = Path(self.directory.name) / ".config" / "river" / "nimzo.config"
        path.parent.mkdir(parents=True)
        path.write_text("unsupported-directive\n")
        env = dict(os.environ, HOME=self.directory.name)
        env.pop("XDG_CONFIG_HOME", None)
        arguments = [str(ROOT / "nimzo"), "--validate"]
        warned = subprocess.run(arguments, env=env, capture_output=True, text=True, timeout=5)
        self.assertEqual(warned.returncode, 0, warned.stderr)
        self.assertIn(f"warning: {path}:1:", warned.stderr)
        path.write_text("bindsym Alt+x exec foot\n")
        valid = subprocess.run(arguments, env=env, capture_output=True, text=True, timeout=5)
        self.assertEqual(valid.returncode, 0, valid.stderr)

    def test_storage_failure_does_not_kill_input(self):
        server = self.start_server(TMPDIR=str(Path(self.directory.name) / "missing"))
        self.assertEqual(server.storage_checks, 0)
        self.assertIsNone(server.process.poll())
        self.assertTrue(any(name == "exit_session" for _, name, _ in server.key(0xFF08, 12)))


if __name__ == "__main__":
    unittest.main()
