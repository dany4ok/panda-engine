"""Panda Engine unified API.

One public port (8081) in front of whichever backend is active. The backend
target is read from panda/state/route.json on every request, so a model switch
is visible immediately without restarting this process.

Uses only the Python standard library. Run with:
    python panda/core/router.py [listen_port]
"""

import ctypes
import http.client
import json
import ntpath
import os
import socket
import struct
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
PANDA = os.path.dirname(HERE)
REPO = os.path.dirname(PANDA)
ROUTE = os.path.join(PANDA, "state", "route.json")
LOG = os.path.join(REPO, "logs", "panda-router.log")

HOP_BY_HOP = {
    "connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
    "te", "trailer", "transfer-encoding", "upgrade", "host",
}

BACKEND_PORTS = {8181, 8182, 8183}
DOTNET_TICKS_FROM_FILETIME = 504911232000000000
TCP_TABLE_OWNER_PID_LISTENER = 3
TCP_TABLE_OWNER_PID_CONNECTIONS = 4
AF_INET = 2
MIB_TCP_STATE_ESTABLISHED = 5


class _MibTcpRowOwnerPid(ctypes.Structure):
    _fields_ = [
        ("state", ctypes.c_uint32),
        ("local_addr", ctypes.c_uint32),
        ("local_port", ctypes.c_uint32),
        ("remote_addr", ctypes.c_uint32),
        ("remote_port", ctypes.c_uint32),
        ("owning_pid", ctypes.c_uint32),
    ]


class _FileTime(ctypes.Structure):
    _fields_ = [("low", ctypes.c_uint32), ("high", ctypes.c_uint32)]


class _UnicodeString(ctypes.Structure):
    _fields_ = [
        ("length", ctypes.c_uint16),
        ("maximum_length", ctypes.c_uint16),
        ("buffer", ctypes.c_void_p),
    ]


class _ProcessBasicInformation(ctypes.Structure):
    _fields_ = [
        ("reserved1", ctypes.c_void_p),
        ("peb_base_address", ctypes.c_void_p),
        ("reserved2", ctypes.c_void_p * 2),
        ("unique_process_id", ctypes.c_size_t),
        ("inherited_from_unique_process_id", ctypes.c_size_t),
    ]


def _tcp_rows(table_class):
    """Read the Windows IPv4 TCP owner table. None means ownership is unavailable."""
    if os.name != "nt":
        return None
    try:
        iphlpapi = ctypes.WinDLL("iphlpapi.dll", use_last_error=True)
        get_table = iphlpapi.GetExtendedTcpTable
        get_table.argtypes = [
            ctypes.c_void_p,
            ctypes.POINTER(ctypes.c_uint32),
            ctypes.c_int,
            ctypes.c_uint32,
            ctypes.c_int,
            ctypes.c_uint32,
        ]
        get_table.restype = ctypes.c_uint32
        size = ctypes.c_uint32(0)
        result = get_table(None, ctypes.byref(size), 0, AF_INET, table_class, 0)
        if result not in (0, 122) or size.value < ctypes.sizeof(ctypes.c_uint32):
            return None
        buffer = ctypes.create_string_buffer(size.value)
        result = get_table(ctypes.byref(buffer), ctypes.byref(size), 0, AF_INET, table_class, 0)
        if result != 0 or size.value < ctypes.sizeof(ctypes.c_uint32):
            return None
        count = ctypes.c_uint32.from_buffer(buffer).value
        row_size = ctypes.sizeof(_MibTcpRowOwnerPid)
        if count > (size.value - ctypes.sizeof(ctypes.c_uint32)) // row_size:
            return None
        rows = []
        offset = ctypes.sizeof(ctypes.c_uint32)
        for index in range(count):
            row = _MibTcpRowOwnerPid.from_buffer(buffer, offset + index * row_size)
            rows.append((
                int(row.state),
                int(row.local_addr),
                int(row.local_port),
                int(row.remote_addr),
                int(row.remote_port),
                int(row.owning_pid),
            ))
        return rows
    except (AttributeError, OSError, ValueError, ctypes.ArgumentError):
        return None


def _ip_from_tcp_value(value):
    return socket.inet_ntoa(struct.pack("<I", value & 0xFFFFFFFF))


def _port_from_tcp_value(value):
    return socket.ntohs(value & 0xFFFF)


def _listener_pids(port):
    rows = _tcp_rows(TCP_TABLE_OWNER_PID_LISTENER)
    if rows is None:
        return None
    pids = {
        pid for state, local_addr, local_port, _, _, pid in rows
        if state == 2
        and _port_from_tcp_value(local_port) == int(port)
        and _ip_from_tcp_value(local_addr) in ("127.0.0.1", "0.0.0.0")
    }
    return pids


def _process_identity(process_id):
    """Return creation time and image path for a live Windows process."""
    if os.name != "nt" or int(process_id) <= 0:
        return None
    kernel32 = ctypes.WinDLL("kernel32.dll", use_last_error=True)
    access = 0x1000 | 0x0400  # PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_QUERY_INFORMATION
    kernel32.OpenProcess.argtypes = [ctypes.c_uint32, ctypes.c_int, ctypes.c_uint32]
    kernel32.OpenProcess.restype = ctypes.c_void_p
    kernel32.GetProcessTimes.argtypes = [
        ctypes.c_void_p,
        ctypes.POINTER(_FileTime),
        ctypes.POINTER(_FileTime),
        ctypes.POINTER(_FileTime),
        ctypes.POINTER(_FileTime),
    ]
    kernel32.GetProcessTimes.restype = ctypes.c_int
    kernel32.QueryFullProcessImageNameW.argtypes = [
        ctypes.c_void_p,
        ctypes.c_uint32,
        ctypes.c_wchar_p,
        ctypes.POINTER(ctypes.c_uint32),
    ]
    kernel32.QueryFullProcessImageNameW.restype = ctypes.c_int
    kernel32.CloseHandle.argtypes = [ctypes.c_void_p]
    kernel32.CloseHandle.restype = ctypes.c_int
    handle = kernel32.OpenProcess(access, 0, int(process_id))
    if not handle:
        return None
    try:
        created = _FileTime()
        exited = _FileTime()
        kernel = _FileTime()
        user = _FileTime()
        if not kernel32.GetProcessTimes(
            handle, ctypes.byref(created), ctypes.byref(exited), ctypes.byref(kernel), ctypes.byref(user)
        ):
            return None
        image = ctypes.create_unicode_buffer(32768)
        image_length = ctypes.c_uint32(len(image))
        if not kernel32.QueryFullProcessImageNameW(handle, 0, image, ctypes.byref(image_length)):
            return None
        filetime = (int(created.high) << 32) | int(created.low)
        return {
            "started_utc_ticks": filetime + DOTNET_TICKS_FROM_FILETIME,
            "executable_path": image.value,
        }
    finally:
        kernel32.CloseHandle(handle)


def _process_command_line(process_id):
    """Read the target process command line using ProcessCommandLineInformation."""
    if os.name != "nt" or int(process_id) <= 0:
        return None
    try:
        kernel32 = ctypes.WinDLL("kernel32.dll", use_last_error=True)
        kernel32.OpenProcess.argtypes = [ctypes.c_uint32, ctypes.c_int, ctypes.c_uint32]
        kernel32.OpenProcess.restype = ctypes.c_void_p
        kernel32.CloseHandle.argtypes = [ctypes.c_void_p]
        kernel32.CloseHandle.restype = ctypes.c_int
        handle = kernel32.OpenProcess(0x1000, 0, int(process_id))  # PROCESS_QUERY_LIMITED_INFORMATION
        if not handle:
            return None
        try:
            ntdll = ctypes.WinDLL("ntdll.dll")
            query = ntdll.NtQueryInformationProcess
            query.argtypes = [
                ctypes.c_void_p,
                ctypes.c_int,
                ctypes.c_void_p,
                ctypes.c_ulong,
                ctypes.POINTER(ctypes.c_ulong),
            ]
            query.restype = ctypes.c_long
            required = ctypes.c_ulong(0)
            status = query(handle, 60, None, 0, ctypes.byref(required))
            if status >= 0 or required.value < ctypes.sizeof(_UnicodeString) + 2:
                return None
            for _ in range(3):
                capacity = int(required.value)
                buffer = ctypes.create_string_buffer(capacity)
                returned = ctypes.c_ulong(0)
                status = query(handle, 60, ctypes.byref(buffer), capacity, ctypes.byref(returned))
                if status == 0:
                    value = _UnicodeString.from_buffer(buffer)
                    length = int(value.length)
                    address = int(value.buffer or 0)
                    base = ctypes.addressof(buffer)
                    if (
                        length % 2
                        or length > int(value.maximum_length)
                        or address < base
                        or address + length > base + capacity
                    ):
                        return None
                    return ctypes.wstring_at(address, length // 2)
                if required.value <= capacity:
                    return None
            return None
        finally:
            kernel32.CloseHandle(handle)
    except (AttributeError, OSError, ValueError, ctypes.ArgumentError):
        return None


def _windows_command_line_args(command_line):
    if os.name != "nt" or not command_line:
        return None
    try:
        shell32 = ctypes.WinDLL("shell32.dll", use_last_error=True)
        kernel32 = ctypes.WinDLL("kernel32.dll", use_last_error=True)
        shell32.CommandLineToArgvW.argtypes = [ctypes.c_wchar_p, ctypes.POINTER(ctypes.c_int)]
        shell32.CommandLineToArgvW.restype = ctypes.POINTER(ctypes.c_wchar_p)
        kernel32.LocalFree.argtypes = [ctypes.c_void_p]
        kernel32.LocalFree.restype = ctypes.c_void_p
        count = ctypes.c_int(0)
        argv = shell32.CommandLineToArgvW(str(command_line), ctypes.byref(count))
        if not argv or count.value <= 0:
            return None
        try:
            return [argv[index] for index in range(count.value)]
        finally:
            kernel32.LocalFree(ctypes.cast(argv, ctypes.c_void_p))
    except (AttributeError, OSError, ValueError, ctypes.ArgumentError):
        return None


def _gameguard_command_is_expected(command_line, executable_path, route, port):
    args = _windows_command_line_args(command_line)
    allowed_configs = route.get("authorizedConfigPaths")
    backend_root = route.get("backendRoot")
    expected_script = route.get("expectedServerScriptPath")
    if (
        not args
        or len(args) != 8
        or not isinstance(allowed_configs, list)
        or not allowed_configs
        or not backend_root
        or not expected_script
    ):
        return False

    normalize_path = lambda value: ntpath.normcase(ntpath.normpath(str(value)))
    if normalize_path(args[0]) != normalize_path(executable_path):
        return False
    script_path = args[1] if ntpath.isabs(args[1]) else ntpath.join(str(backend_root), args[1])
    if normalize_path(script_path) != normalize_path(expected_script):
        return False
    if args[2:5] != ["--engine", "strata", "--config"]:
        return False
    if not any(normalize_path(args[5]) == normalize_path(config) for config in allowed_configs):
        return False
    return args[6:] == ["--port", str(int(port))]


def _parent_process_id(process_id):
    if os.name != "nt" or int(process_id) <= 0:
        return None
    kernel32 = ctypes.WinDLL("kernel32.dll", use_last_error=True)
    kernel32.OpenProcess.argtypes = [ctypes.c_uint32, ctypes.c_int, ctypes.c_uint32]
    kernel32.OpenProcess.restype = ctypes.c_void_p
    kernel32.CloseHandle.argtypes = [ctypes.c_void_p]
    kernel32.CloseHandle.restype = ctypes.c_int
    handle = kernel32.OpenProcess(0x1000 | 0x0400, 0, int(process_id))
    if not handle:
        return None
    try:
        ntdll = ctypes.WinDLL("ntdll.dll")
        query = ntdll.NtQueryInformationProcess
        query.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_void_p, ctypes.c_ulong, ctypes.c_void_p]
        query.restype = ctypes.c_long
        info = _ProcessBasicInformation()
        status = query(handle, 0, ctypes.byref(info), ctypes.sizeof(info), None)
        if status < 0:
            return None
        return int(info.inherited_from_unique_process_id)
    finally:
        kernel32.CloseHandle(handle)


def _is_descendant_or_self(process_id, root_process_id):
    process_id = int(process_id)
    root_process_id = int(root_process_id)
    if process_id == root_process_id:
        return True
    seen = set()
    current = process_id
    for _ in range(64):
        if current <= 0 or current in seen:
            return False
        seen.add(current)
        parent = _parent_process_id(current)
        if parent is None or parent <= 0:
            return False
        if parent == root_process_id:
            return True
        current = parent
    return False


def _route_owner_valid(route, port, connected_listener_pid=None):
    """Fail closed unless the configured listener is the recorded owner or its child."""
    if os.name != "nt" or not isinstance(route, dict) or int(port) not in BACKEND_PORTS:
        return False
    owner = route.get("owner")
    listener = route.get("listener")
    if not isinstance(owner, dict) or not isinstance(listener, dict):
        return False
    try:
        owner_pid = int(owner["processId"])
        listener_pid = int(listener["processId"])
        route_port = int(route["port"])
        owner_port = int(owner["port"])
        owner_ticks = int(owner["startedUtcTicks"])
        listener_ticks = int(listener["startedUtcTicks"])
        if route_port != int(port) or owner_port != int(port):
            return False
        if str(owner["modelId"]) != str(route.get("model", "")):
            return False
        role = str(owner["role"])
        if role not in ("Server", "InklingLauncher", "GameGuard"):
            return False
        if str(route.get("generation", "")) == "":
            return False
        if str(route.get("kind", "")) not in ("inkling", "mini", "gyro"):
            return False
    except (KeyError, TypeError, ValueError):
        return False

    root_identity = _process_identity(owner_pid)
    if not root_identity:
        return False
    if int(root_identity["started_utc_ticks"]) != owner_ticks:
        return False
    if ntpath.normcase(ntpath.normpath(root_identity["executable_path"])) != ntpath.normcase(
        ntpath.normpath(str(owner.get("executablePath", "")))
    ):
        return False
    owner_command_line = _process_command_line(owner_pid)
    if owner_command_line is None or owner_command_line != str(owner.get("commandLine", "")):
        return False

    pids = _listener_pids(port)
    if pids is None or len(pids) != 1:
        return False
    actual_listener_pid = next(iter(pids))
    if connected_listener_pid is not None and actual_listener_pid != int(connected_listener_pid):
        return False
    if connected_listener_pid is None and actual_listener_pid != listener_pid and owner["role"] != "GameGuard":
        return False

    listener_identity = _process_identity(actual_listener_pid)
    if not listener_identity:
        return False
    if ntpath.normcase(ntpath.normpath(listener_identity["executable_path"])) != ntpath.normcase(
        ntpath.normpath(str(listener.get("executablePath", "")))
    ):
        return False

    listener_command_line = _process_command_line(actual_listener_pid)
    if listener_command_line is None:
        return False
    if actual_listener_pid == listener_pid:
        if int(listener_identity["started_utc_ticks"]) != listener_ticks:
            return False
        if listener_command_line != str(listener.get("commandLine", "")):
            return False

    if role == "GameGuard":
        if actual_listener_pid != listener_pid:
            if not _gameguard_command_is_expected(
                listener_command_line,
                listener_identity["executable_path"],
                route,
                port,
            ):
                return False
            if int(listener_identity["started_utc_ticks"]) <= owner_ticks:
                return False
        return (
            route.get("kind") == "mini"
            and ntpath.basename(listener_identity["executable_path"]).casefold() in ("python.exe", "pythonw.exe")
            and _is_descendant_or_self(actual_listener_pid, owner_pid)
        )
    if int(listener_identity["started_utc_ticks"]) != listener_ticks:
        return False
    if actual_listener_pid != listener_pid or not _is_descendant_or_self(actual_listener_pid, owner_pid):
        return False
    if role == "Server":
        return actual_listener_pid == owner_pid
    if role == "InklingLauncher":
        return (
            route.get("kind") == "inkling"
            and ntpath.basename(listener_identity["executable_path"]).casefold() == "ninfer-serve.exe"
        )
    return False


def _connected_listener_pid(sock, port):
    """Return the process on the established loopback socket's server side."""
    try:
        local_addr, local_port = sock.getsockname()[:2]
        peer_addr, peer_port = sock.getpeername()[:2]
        if local_addr != "127.0.0.1" or peer_addr != "127.0.0.1" or int(peer_port) != int(port):
            return None
    except (OSError, TypeError, ValueError):
        return None
    rows = _tcp_rows(TCP_TABLE_OWNER_PID_CONNECTIONS)
    if rows is None:
        return None
    pids = {
        pid for state, local_ip, local_tcp_port, remote_ip, remote_tcp_port, pid in rows
        if state == MIB_TCP_STATE_ESTABLISHED
        and _ip_from_tcp_value(local_ip) == peer_addr
        and _port_from_tcp_value(local_tcp_port) == int(port)
        and _ip_from_tcp_value(remote_ip) == local_addr
        and _port_from_tcp_value(remote_tcp_port) == int(local_port)
    }
    if len(pids) != 1:
        return None
    return next(iter(pids))


def _open_verified_connection(port, route):
    if int(port) not in BACKEND_PORTS or not _route_owner_valid(route, port):
        return None
    connection = http.client.HTTPConnection("127.0.0.1", int(port), timeout=600)
    try:
        connection.connect()
        if connection.sock is None:
            connection.close()
            return None
        listener_pid = None
        for _ in range(3):
            listener_pid = _connected_listener_pid(connection.sock, port)
            if listener_pid is not None:
                break
            time.sleep(0.01)
        if listener_pid is None or not _route_owner_valid(route, port, listener_pid):
            connection.close()
            return None
        return connection
    except (OSError, http.client.HTTPException):
        connection.close()
        return None


def _health_from_verified_connection(connection, route):
    try:
        connection.request("GET", "/health", headers={"Connection": "close"})
        response = connection.getresponse()
        if response.status != 200:
            response.read()
            return False
        payload = response.read(65537)
        if len(payload) > 65536:
            return False
        try:
            health = json.loads(payload.decode("utf-8"))
        except (UnicodeDecodeError, ValueError):
            health = payload.decode("utf-8", errors="replace").strip()
        if health == "ok":
            status_ok = True
        elif isinstance(health, dict):
            status_ok = str(health.get("status", "")).casefold() == "ok"
        else:
            status_ok = False
        if not status_ok:
            return False
        if route.get("kind") in ("mini", "gyro"):
            return (
                isinstance(health, dict)
                and str(health.get("model", "")).casefold() == str(route.get("expectedModelName", "")).casefold()
            )
        return route.get("kind") == "inkling"
    except (OSError, http.client.HTTPException, ValueError):
        return False
    finally:
        connection.close()


def _backend_ready_for_request(port, route):
    connection = _open_verified_connection(port, route)
    return connection is not None and _health_from_verified_connection(connection, route)


def _same_route_generation(first, second):
    return bool(
        isinstance(first, dict)
        and isinstance(second, dict)
        and first.get("generation")
        and first.get("generation") == second.get("generation")
        and first.get("model") == second.get("model")
        and first.get("port") == second.get("port")
    )


def log(message):
    try:
        os.makedirs(os.path.dirname(LOG), exist_ok=True)
        if os.path.exists(LOG) and os.path.getsize(LOG) > 5 * 1024 * 1024:
            os.replace(LOG, LOG[:-4] + ".old.log")
        with open(LOG, "a", encoding="utf-8") as fh:
            fh.write("[%s] %s\n" % (time.strftime("%Y-%m-%d %H:%M:%S"), message))
    except OSError:
        pass


def read_route():
    """Return listen port, target port, name, and the ownership-bearing route."""
    listen, target, name, route = 8081, 0, "", {}
    try:
        # PowerShell 5.1 writes UTF-8 with a BOM; utf-8-sig accepts both forms.
        with open(ROUTE, "r", encoding="utf-8-sig") as fh:
            data = json.load(fh)
        if not isinstance(data, dict):
            raise ValueError("route must be a JSON object")
        listen = int(data.get("listen", listen))
        target = int(data.get("port", 0))
        name = str(data.get("name", ""))
        route = data
    except FileNotFoundError:
        pass
    except (ValueError, TypeError, OSError) as exc:
        log("bad route file: %s" % exc)
    return listen, target, name, route


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "PandaEngine/1.0"

    def log_message(self, fmt, *args):
        pass

    def _json(self, code, obj):
        body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)

    def _status(self, target, name, route):
        up = False
        active = ""
        if target in BACKEND_PORTS:
            connection = _open_verified_connection(target, route)
            if connection is not None:
                up = _health_from_verified_connection(connection, route)
            if up:
                active = name
        self._json(200, {
            "engine": "Panda Engine",
            "api": "http://127.0.0.1:%d" % self.server.listen_port,
            "active": active,
            "upstream_port": target,
            "upstream_up": up,
        })

    def _read_body(self):
        if "chunked" in self.headers.get("Transfer-Encoding", "").lower():
            data = bytearray()
            while True:
                line = self.rfile.readline().strip()
                if not line:
                    break
                size = int(line.split(b";", 1)[0], 16)
                if size == 0:
                    while True:
                        trailer = self.rfile.readline()
                        if trailer in (b"\r\n", b"\n", b""):
                            break
                    break
                data.extend(self.rfile.read(size))
                self.rfile.read(2)
            return bytes(data) or None
        length = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(length) if length else None

    def _handle(self):
        _, target, name, route = read_route()
        if self.path.split("?", 1)[0] == "/_panda/status":
            self._status(target, name, route)
            return
        if target not in BACKEND_PORTS:
            self._json(503, {"error": "no active backend", "hint": "press S in Panda Engine"})
            return
        if not _backend_ready_for_request(target, route):
            self._json(503, {"error": "backend ownership or health validation failed"})
            return
        connection = _open_verified_connection(target, route)
        if connection is None:
            self._json(503, {"error": "backend ownership validation failed"})
            return
        _, current_target, _, current_route = read_route()
        if current_target != target or not _same_route_generation(route, current_route):
            connection.close()
            self._json(503, {"error": "backend route changed; retry the request"})
            return
        # BaseHTTPRequestHandler already answers Expect: 100-continue in HTTP/1.1.
        body = self._read_body()
        headers = {k: v for k, v in self.headers.items() if k.lower() not in HOP_BY_HOP}
        headers["Connection"] = "close"
        _, current_target, _, current_route = read_route()
        if current_target != target or not _same_route_generation(route, current_route):
            connection.close()
            self._json(503, {"error": "backend route changed; retry the request"})
            return
        started = time.time()
        try:
            connection.request(self.command, self.path, body=body, headers=headers)
            upstream = connection.getresponse()
        except Exception as exc:
            connection.close()
            log("%s %s -> %d FAILED: %s" % (self.command, self.path, target, exc))
            self._json(502, {"error": "upstream unreachable", "port": target, "detail": str(exc)})
            return

        status = upstream.status
        try:
            self.send_response(status)
            for key, value in upstream.getheaders():
                if key.lower() not in HOP_BY_HOP:
                    self.send_header(key, value)
            # No chunked encoding on the way out: the connection closes at the end,
            # which also lets token streams (no Content-Length) reach the client live.
            self.send_header("Connection", "close")
            self.end_headers()
            if self.command != "HEAD":
                while True:
                    chunk = upstream.read1(65536)
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass
        finally:
            upstream.close()
            connection.close()
        log("%s %s -> %d %d %dms" % (
            self.command, self.path, target, status, int((time.time() - started) * 1000)))

    do_GET = _handle
    do_POST = _handle
    do_PUT = _handle
    do_PATCH = _handle
    do_DELETE = _handle
    do_HEAD = _handle
    do_OPTIONS = _handle


def main():
    # The public port is fixed by design; route.json only holds the backend target.
    listen = 8081
    if len(sys.argv) > 1:
        try:
            listen = int(sys.argv[1])
        except ValueError:
            pass
    try:
        server = ThreadingHTTPServer(("127.0.0.1", listen), Handler)
    except OSError as exc:
        log("cannot bind 127.0.0.1:%d: %s" % (listen, exc))
        print("Panda API: cannot bind 127.0.0.1:%d (%s)" % (listen, exc))
        return 1
    server.daemon_threads = True
    server.listen_port = listen
    log("Panda API listening on 127.0.0.1:%d" % listen)
    print("Panda API listening on http://127.0.0.1:%d/v1" % listen, flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
