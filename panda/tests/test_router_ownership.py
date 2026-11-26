import importlib.util
import json
import os
import pathlib
import unittest
from unittest import mock


ROUTER_PATH = pathlib.Path(__file__).parents[1] / "core" / "router.py"
SPEC = importlib.util.spec_from_file_location("panda_router_under_test", ROUTER_PATH)
router = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(router)


class RouterOwnershipTests(unittest.TestCase):
    def setUp(self):
        self.route = {
            "version": 2,
            "generation": "test-generation",
            "port": 8183,
            "model": "gyro-s",
            "kind": "gyro",
            "expectedModelName": "panda/gyro-gyro-s",
            "owner": {
                "processId": 101,
                "startedUtcTicks": 1000,
                "executablePath": r"C:\Panda\backend.exe",
                "commandLine": r"backend.exe --port 8183",
                "modelId": "gyro-s",
                "port": 8183,
                "role": "Server",
            },
            "listener": {
                "processId": 101,
                "startedUtcTicks": 1000,
                "executablePath": r"C:\Panda\backend.exe",
                "commandLine": r"backend.exe --port 8183",
            },
        }
        self.identity = {
            "started_utc_ticks": 1000,
            "executable_path": r"C:\Panda\backend.exe",
        }

    def _identity_mocks(self):
        return (
            mock.patch.object(router, "_process_identity", return_value=self.identity),
            mock.patch.object(router, "_process_command_line", return_value=r"backend.exe --port 8183"),
            mock.patch.object(router, "_listener_pids", return_value={101}),
            mock.patch.object(router, "_is_descendant_or_self", return_value=True),
        )

    def test_recorded_listener_is_accepted(self):
        with (
            mock.patch.object(router.os, "name", "nt"),
            self._identity_mocks()[0],
            self._identity_mocks()[1],
            self._identity_mocks()[2],
            self._identity_mocks()[3],
        ):
            self.assertTrue(router._route_owner_valid(self.route, 8183))

    def test_owner_command_line_mismatch_is_rejected(self):
        with (
            mock.patch.object(router.os, "name", "nt"),
            mock.patch.object(router, "_process_identity", return_value=self.identity),
            mock.patch.object(router, "_process_command_line", return_value="backend.exe --other-model"),
        ):
            self.assertFalse(router._route_owner_valid(self.route, 8183))

    def test_recorded_python_child_listener_is_accepted(self):
        self.route["listener"] = {
            "processId": 202, "startedUtcTicks": 2000,
            "executablePath": r"C:\Python315\python.exe",
            "commandLine": "python server.py",
        }
        identities = {101: self.identity, 202: {
            "started_utc_ticks": 2000, "executable_path": r"C:\Python315\python.exe",
        }}
        commands = {101: r"backend.exe --port 8183", 202: "python server.py"}
        with (
            mock.patch.object(router.os, "name", "nt"),
            mock.patch.object(router, "_process_identity", side_effect=identities.get),
            mock.patch.object(router, "_process_command_line", side_effect=commands.get),
            mock.patch.object(router, "_listener_pids", return_value={202}),
            mock.patch.object(router, "_is_descendant_or_self", return_value=True),
        ):
            self.assertTrue(router._route_owner_valid(self.route, 8183))

    def test_descendant_rejects_reused_parent_pid(self):
        identities = {202: {"started_utc_ticks": 1000}, 101: {"started_utc_ticks": 2000}}
        with (
            mock.patch.object(router, "_parent_process_id", return_value=101),
            mock.patch.object(router, "_process_identity", side_effect=identities.get),
        ):
            self.assertFalse(router._is_descendant_or_self(202, 101))

    def test_unrelated_process_taking_backend_port_is_rejected(self):
        with (
            mock.patch.object(router.os, "name", "nt"),
            mock.patch.object(router, "_process_identity", return_value=self.identity),
            mock.patch.object(router, "_listener_pids", return_value={202}),
            mock.patch.object(router, "_is_descendant_or_self", return_value=True),
        ):
            self.assertFalse(router._route_owner_valid(self.route, 8183))

    def test_reused_owner_pid_is_rejected(self):
        with (
            mock.patch.object(router.os, "name", "nt"),
            mock.patch.object(router, "_process_identity", return_value=None),
            mock.patch.object(router, "_listener_pids", return_value={101}),
        ):
            self.assertFalse(router._route_owner_valid(self.route, 8183))

    def test_wrong_backend_health_model_is_rejected(self):
        class Response:
            status = 200

            def read(self, _limit=None):
                return json.dumps({"status": "ok", "model": "different-model"}).encode()

        class Connection:
            closed = False

            def request(self, *_args, **_kwargs):
                pass

            def getresponse(self):
                return Response()

            def close(self):
                self.closed = True

        connection = Connection()
        self.assertFalse(router._health_from_verified_connection(connection, self.route))
        self.assertTrue(connection.closed)

    def test_request_readiness_requires_verified_healthy_backend(self):
        connection = mock.Mock()
        with (
            mock.patch.object(router, "_open_verified_connection", return_value=connection) as open_connection,
            mock.patch.object(router, "_health_from_verified_connection", return_value=False) as check_health,
        ):
            self.assertFalse(router._backend_ready_for_request(8183, self.route))
        open_connection.assert_called_once_with(8183, self.route)
        check_health.assert_called_once_with(connection, self.route)

    def test_unowned_route_is_rejected_before_connect(self):
        connection_factory = mock.Mock()
        with (
            mock.patch.object(router, "_route_owner_valid", return_value=False),
            mock.patch.object(router.http.client, "HTTPConnection", connection_factory),
        ):
            self.assertIsNone(router._open_verified_connection(8183, self.route))
        connection_factory.assert_not_called()

    def test_gameguard_restart_requires_an_authorized_config_child(self):
        route = dict(self.route)
        route.update({"port": 8182, "model": "minicpm-q4km", "kind": "mini"})
        route["owner"] = {
            "processId": 101,
            "startedUtcTicks": 1000,
            "executablePath": r"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe",
            "commandLine": r"powershell.exe -File C:\Panda\vram-guard.ps1 -Port 8182",
            "modelId": "minicpm-q4km",
            "port": 8182,
            "role": "GameGuard",
        }
        route["listener"] = {
            "processId": 202,
            "startedUtcTicks": 1100,
            "executablePath": r"C:\Python\python.exe",
            "commandLine": r"C:\Python\python.exe serve\server.py --engine panda --config C:\Models\fast.json --port 8182",
        }
        route["backendRoot"] = r"C:\Models"
        route["expectedServerScriptPath"] = r"C:\Models\serve\server.py"
        route["authorizedConfigPaths"] = [
            r"C:\Models\fast.json",
            r"C:\Models\cpu.json",
        ]
        identities = {
            101: {
                "started_utc_ticks": 1000,
                "executable_path": route["owner"]["executablePath"],
            },
            303: {
                "started_utc_ticks": 2000,
                "executable_path": route["listener"]["executablePath"],
            },
        }
        command_lines = {
            101: route["owner"]["commandLine"],
            303: r"C:\Python\python.exe serve\server.py --engine panda --config C:\Models\cpu.json --port 8182",
        }
        with (
            mock.patch.object(router.os, "name", "nt"),
            mock.patch.object(router, "_process_identity", side_effect=identities.get),
            mock.patch.object(router, "_process_command_line", side_effect=command_lines.get),
            mock.patch.object(router, "_listener_pids", return_value={303}),
            mock.patch.object(router, "_is_descendant_or_self", return_value=True),
        ):
            self.assertTrue(router._route_owner_valid(route, 8182))

        command_lines[303] = r"C:\Python\python.exe unrelated.py --engine panda --config C:\Models\cpu.json --port 8182"
        with (
            mock.patch.object(router.os, "name", "nt"),
            mock.patch.object(router, "_process_identity", side_effect=identities.get),
            mock.patch.object(router, "_process_command_line", side_effect=command_lines.get),
            mock.patch.object(router, "_listener_pids", return_value={303}),
            mock.patch.object(router, "_is_descendant_or_self", return_value=True),
        ):
            self.assertFalse(router._route_owner_valid(route, 8182))

    @unittest.skipUnless(os.name == "nt", "Windows process APIs are required")
    def test_current_process_command_line_is_readable(self):
        self.assertTrue(router._process_command_line(os.getpid()))


if __name__ == "__main__":
    unittest.main()
