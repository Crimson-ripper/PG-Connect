"""Contract tests for the mock backend: py -I test_mock_backend.py"""
import json
import threading
import unittest
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer
from pathlib import Path
import importlib.util

spec = importlib.util.spec_from_file_location("mock_backend", Path(__file__).with_name("mock_backend.py"))
mock = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mock)


def post(base, path, body):
    req = urllib.request.Request(base + path, data=json.dumps(body).encode(), method="POST",
                                 headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=5) as r:
            return r.status, json.loads(r.read())
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read())


class MockBackendTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        mock.main.__globals__["ARGS"] = None
        import argparse
        mock.ARGS = argparse.Namespace(host_address="192.0.2.10", http_port=47989, app_name="Steam",
                                       sunshine_url=None, sunshine_user="admin", fake_host=False)
        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), mock.Handler)
        cls.base = f"http://127.0.0.1:{cls.server.server_address[1]}"
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()

    def test_direct_session(self):
        status, s = post(self.base, "/api/gamezone/sessions/TEST1234/connect", {"client": {"name": "t"}})
        self.assertEqual(status, 200)
        self.assertEqual(s["network"]["mode"], "direct")
        self.assertEqual(s["host"]["address"], "192.0.2.10")
        self.assertRegex(s["pairing"]["pin"], r"^\d{4}$")
        self.assertEqual(s["app"]["name"], "Steam")

        status, _ = post(self.base, "/api/gamezone/sessions/TEST1234/pairing",
                         {"session_id": s["session_id"], "pair_token": s["pairing"]["pair_token"]})
        self.assertEqual(status, 202)
        status, _ = post(self.base, "/api/gamezone/sessions/TEST1234/pairing",
                         {"session_id": s["session_id"], "pair_token": "wrong"})
        self.assertEqual(status, 403)
        status, _ = post(self.base, "/api/gamezone/sessions/TEST1234/events",
                         {"session_id": s["session_id"], "event": "stream_started"})
        self.assertEqual(status, 202)

    def test_wireguard_session_needs_client_key(self):
        status, _ = post(self.base, "/api/gamezone/sessions/WGTEST12/connect", {})
        self.assertEqual(status, 400)
        status, s = post(self.base, "/api/gamezone/sessions/WGTEST12/connect", {"wireguard_public_key": "x"})
        self.assertEqual(status, 200)
        wg = s["network"]["wireguard"]
        self.assertEqual(wg["host_tunnel_address"], "10.77.0.1")
        self.assertFalse(wg["allowed_ips"].endswith("/0"))

    def test_error_codes(self):
        self.assertEqual(post(self.base, "/api/gamezone/sessions/BOOTING1/connect", {})[0], 409)
        self.assertEqual(post(self.base, "/api/gamezone/sessions/EXPIRED1/connect", {})[0], 410)
        self.assertEqual(post(self.base, "/api/gamezone/sessions/NOPE0000/connect", {})[0], 404)
        self.assertEqual(post(self.base, "/api/gamezone/sessions/TEST1234/pairing", {"session_id": "x"})[0], 404)


if __name__ == "__main__":
    unittest.main()
