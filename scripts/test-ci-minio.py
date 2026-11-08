#!/usr/bin/env python3
"""ELZ-066 controls for scripts/ci-minio.py: fake HTTP, fake process, no network, no real server."""
import datetime
import hashlib
import http.client
import http.server
import importlib.util
import pathlib
import shutil
import sys
import tempfile
import threading
import unittest
import urllib.error

ROOT = pathlib.Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("ci_minio", ROOT / "scripts" / "ci-minio.py")
minio = importlib.util.module_from_spec(spec)
sys.dont_write_bytecode = True
spec.loader.exec_module(minio)

BINARY = b"#!/bin/sh\necho fake minio\n" * 40
REAL_SIZE, REAL_SHA = minio.SIZE, minio.SHA256


def pin_test_binary():
    minio.SIZE = len(BINARY)
    minio.SHA256 = hashlib.sha256(BINARY).hexdigest()


def unpin():
    minio.SIZE, minio.SHA256 = REAL_SIZE, REAL_SHA


class FakeNet:
    """Answers by URL prefix: scripted answers per URL, a call log with the headers sent."""

    def __init__(self, api=None, storage=None, browser=None, browser_storage=None,
                 location="https://release-assets.githubusercontent.com/github-production-release-asset/1/x?sig=a%2Bb"):
        self.api = list(api if api is not None else [(302, {"Location": location}, b"")])
        self.storage = list(storage if storage is not None else [(200, {}, BINARY)])
        self.browser = list(browser if browser is not None else [(302, {"Location": location}, b"")])
        self.calls = []
        self.sleeps = []
        self.location = location

    def get(self, url, headers, timeout=60):
        self.calls.append((url, dict(headers)))
        if url == minio.API_URL:
            queue = self.api
        elif url == minio.BROWSER_URL:
            queue = self.browser
        else:
            queue = self.storage
        answer = queue.pop(0) if len(queue) > 1 else queue[0]
        if isinstance(answer, Exception):
            raise answer
        return answer

    def sleep(self, seconds):
        self.sleeps.append(seconds)


class Clock:
    def __init__(self):
        self.now = 0.0

    def __call__(self):
        return self.now

    def sleep(self, seconds):
        self.now += seconds


class ObtainTest(unittest.TestCase):
    def setUp(self):
        pin_test_binary()
        self.addCleanup(unpin)
        self.cache = pathlib.Path(tempfile.mkdtemp(prefix="elzoo-minio-test-"))
        self.addCleanup(shutil.rmtree, self.cache, True)
        self.clock = Clock()

    def obtain(self, net, token="job-token"):
        return minio.obtain(self.cache, token, get=net.get, sleep=lambda s: (net.sleep(s), self.clock.sleep(s)),
                            clock=self.clock)

    def test_pins_are_the_reviewed_release_values(self):
        self.assertEqual("RELEASE.2025-09-07T16-13-09Z", minio.VERSION)
        self.assertEqual(404655976, minio.ASSET_ID)
        self.assertEqual(110_989_496, REAL_SIZE)
        self.assertEqual("7c5bd8512c6e966455b1d198209358b2d191c77a83ab377c4073281065fb855f", REAL_SHA)
        self.assertEqual("https://api.github.com/repos/minio/minio/releases/assets/404655976", minio.API_URL)
        self.assertEqual("https://github.com/minio/minio/releases/download/RELEASE.2025-09-07T16-13-09Z/"
                         "minio.linux-amd64.RELEASE.2025-09-07T16-13-09Z", minio.BROWSER_URL)

    def test_verified_cache_entry_is_used_without_any_request(self):
        (self.cache / "minio").write_bytes(BINARY)
        net = FakeNet()
        data, source = self.obtain(net)
        self.assertEqual((BINARY, "cache"), (data, source))
        self.assertEqual([], net.calls)

    def test_corrupt_cache_entry_is_deleted_and_the_api_is_used(self):
        for corrupt in (BINARY + b"x", BINARY[:-1], b"x" * len(BINARY), b""):
            with self.subTest(size=len(corrupt)):
                (self.cache / "minio").write_bytes(corrupt)
                net = FakeNet()
                data, source = self.obtain(net)
                self.assertEqual("release-asset API", source)
                self.assertEqual(BINARY, data)

    def test_api_route_sends_the_token_to_the_api_only(self):
        net = FakeNet()
        data, source = self.obtain(net)
        self.assertEqual(("release-asset API", BINARY), (source, data))
        api_call, storage_call = net.calls[0], net.calls[1]
        self.assertEqual(minio.API_URL, api_call[0])
        self.assertEqual("Bearer job-token", api_call[1]["Authorization"])
        self.assertEqual("application/octet-stream", api_call[1]["Accept"])
        self.assertNotIn("Authorization", storage_call[1])
        self.assertTrue(storage_call[0].startswith("https://release-assets.githubusercontent.com/"))

    def test_without_a_token_no_authorization_header_is_sent(self):
        net = FakeNet()
        self.obtain(net, token=None)
        self.assertTrue(all("Authorization" not in headers for _url, headers in net.calls))

    def test_api_failure_falls_back_to_the_browser_url_without_the_token(self):
        for api in ([(404, {}, b"")], [(403, {}, b"")], [(500, {}, b"")], [urllib.error.URLError("down")],
                    [(200, {}, BINARY + b"x")], [(200, {}, b"wrong")]):
            with self.subTest(api=str(api)[:40]):
                self.setUp()
                net = FakeNet(api=api)
                data, source = self.obtain(net)
                self.assertEqual(("browser URL", BINARY), (source, data))
                browser_call = [c for c in net.calls if c[0] == minio.BROWSER_URL][0]
                self.assertNotIn("Authorization", browser_call[1])

    def test_a_hash_mismatch_from_the_first_source_is_not_accepted_and_the_second_is_tried(self):
        wrong = bytes([BINARY[0] ^ 1]) + BINARY[1:]  # same size, different content
        net = FakeNet(storage=[(200, {}, wrong), (200, {}, BINARY)])
        data, source = self.obtain(net)
        self.assertEqual(("browser URL", BINARY), (source, data))

    def test_every_source_failing_stops_with_the_reasons(self):
        net = FakeNet(api=[(404, {}, b"")], browser=[(404, {}, b"")])
        with self.assertRaisesRegex(minio.Stop, r"no source gave the pinned binary \(release-asset API: .*HTTP 404.*browser URL: .*HTTP 404"):
            self.obtain(net)

    def test_5xx_and_network_errors_are_retried_with_backoff_other_statuses_are_not(self):
        net = FakeNet(api=[(503, {}, b""), (503, {}, b""), (302, {"Location": FakeNet().location}, b"")])
        self.obtain(net)
        self.assertEqual([2, 4], net.sleeps)
        for status in (401, 403, 404, 429):
            with self.subTest(status=status):
                self.setUp()
                net = FakeNet(api=[(status, {}, b"")], browser=[(status, {}, b"")])
                with self.assertRaises(minio.Stop):
                    self.obtain(net)
                self.assertEqual([], net.sleeps)

    def test_unexpected_redirect_hosts_are_refused(self):
        for location in ("https://evil.example/x", "http://release-assets.githubusercontent.com/x", "",
                         "https://githubusercontent.com.evil.example/x", "https://github.com@evil.example/x"):
            with self.subTest(location=location):
                self.setUp()
                net = FakeNet(api=[(302, {"Location": location}, b"")], browser=[(302, {"Location": location}, b"")])
                with self.assertRaises(minio.Stop):
                    self.obtain(net)
                self.assertTrue(all(not url.startswith("https://evil") for url, _h in net.calls))

    def test_the_download_time_budget_is_bounded(self):
        class Slow(FakeNet):
            def get(self, url, headers, timeout=60):
                self.calls.append((url, dict(headers)))
                raise TimeoutError("slow")
        net = Slow()
        with self.assertRaises(minio.Stop):
            minio.obtain(self.cache, "t", get=net.get, sleep=lambda s: self.clock.sleep(s + 200), clock=self.clock)
        self.assertLessEqual(len(net.calls), 2 * minio.ATTEMPTS)

    def test_exceptions_from_the_transport_never_escape(self):
        for error in (http.client.IncompleteRead(b"x"), http.client.BadStatusLine("x"), ValueError("bad"),
                      OSError("reset"), TimeoutError("t")):
            with self.subTest(error=type(error).__name__):
                self.setUp()
                net = FakeNet(api=[error], browser=[error])
                with self.assertRaises(minio.Stop):
                    self.obtain(net)

    def test_redirect_hosts_are_parsed_strictly(self):
        for location in ("https://evilgithubusercontent.com/x", "https://github.com:8443/x", "https://user@github.com/x",
                         "https://github.com\\@evil.example/x", "https://evil%2f.github.com/x", "ftp://github.com/x",
                         "https://exaмple.githubusercontent.com/x", "https://github..com/x"):
            with self.subTest(location=location):
                self.assertFalse(minio.redirect_allowed(location))
        self.assertTrue(minio.redirect_allowed("https://release-assets.githubusercontent.com/a?sig=a%2Bb"))

    def test_http_get_does_not_follow_a_redirect(self):
        seen = {"a": [], "b": []}

        def make(name, redirect_to=None):
            class Handler(http.server.BaseHTTPRequestHandler):
                def do_GET(self):
                    seen[name].append(dict(self.headers))
                    if redirect_to:
                        self.send_response(302)
                        self.send_header("Location", redirect_to())
                        self.end_headers()
                    else:
                        self.send_response(200)
                        self.end_headers()
                        self.wfile.write(b"target")

                def log_message(self, *args):
                    pass
            server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
            threading.Thread(target=server.serve_forever, daemon=True).start()
            return server
        target = make("b")
        first = make("a", redirect_to=lambda: f"http://127.0.0.1:{target.server_port}/signed")
        try:
            status, headers, _body = minio.http_get(f"http://127.0.0.1:{first.server_port}/x", {"Authorization": "Bearer s"})
        finally:
            for server in (first, target):
                server.shutdown()
                server.server_close()
        self.assertEqual(302, status)
        self.assertEqual([], seen["b"])


class SigV4Test(unittest.TestCase):
    def test_signature_matches_the_aws_documentation_example(self):
        now = datetime.datetime(2013, 5, 24, 0, 0, 0, tzinfo=datetime.timezone.utc)
        headers = minio.sigv4_headers("GET", "examplebucket.s3.amazonaws.com", "/test.txt", "AKIAIOSFODNN7EXAMPLE",
                                      "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY", now, region="us-east-1",
                                      extra={"range": "bytes=0-9"})
        self.assertIn("Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request", headers["Authorization"])
        self.assertIn("SignedHeaders=host;range;x-amz-content-sha256;x-amz-date", headers["Authorization"])
        self.assertIn("Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41", headers["Authorization"])

    def test_check_bucket_accepts_only_200(self):
        class Response:
            def __init__(self, status):
                self.status = status

            def __enter__(self):
                return self

            def __exit__(self, *args):
                return False

        def opener(status):
            def call(request, timeout):
                self.assertEqual("HEAD", request.get_method())
                self.assertEqual("/elzoo-test", request.selector)
                self.assertIn("AWS4-HMAC-SHA256", request.headers["Authorization"])
                if status == 200:
                    return Response(200)
                raise urllib.error.HTTPError(request.full_url, status, "x", {}, None)
            return call
        minio.check_bucket("http://127.0.0.1:9000", "a", "s", urlopen=opener(200))
        for status in (403, 404, 500):
            with self.subTest(status=status):
                with self.assertRaisesRegex(minio.Stop, f"HTTP {status}"):
                    minio.check_bucket("http://127.0.0.1:9000", "a", "s", urlopen=opener(status))

        def broken(request, timeout):
            raise urllib.error.URLError("refused")
        with self.assertRaisesRegex(minio.Stop, "failed"):
            minio.check_bucket("http://127.0.0.1:9000", "a", "s", urlopen=broken)


class HealthTest(unittest.TestCase):
    def test_both_endpoints_must_answer_200(self):
        clock = Clock()
        seen = []

        def get(url, headers, timeout=5):
            seen.append(url)
            return 200, {}, b""
        minio.wait_health("http://127.0.0.1:9000", clock.sleep, clock, get=get)
        self.assertEqual(["http://127.0.0.1:9000/minio/health/live", "http://127.0.0.1:9000/minio/health/ready"], seen)

    def test_late_start_is_waited_for_and_a_dead_process_stops_at_once(self):
        clock = Clock()
        answers = [OSError("refused"), OSError("refused"), (200, {}, b""), (503, {}, b""), (200, {}, b"")]

        def get(url, headers, timeout=5):
            answer = answers.pop(0)
            if isinstance(answer, Exception):
                raise answer
            return answer
        minio.wait_health("http://127.0.0.1:9000", clock.sleep, clock, get=get)
        with self.assertRaisesRegex(minio.Stop, "ended before"):
            minio.wait_health("http://127.0.0.1:9000", clock.sleep, clock, alive=lambda: False, get=get)

    def test_timeout_names_the_endpoint(self):
        clock = Clock()
        with self.assertRaisesRegex(minio.Stop, r"/minio/health/live did not answer 200 in 5 s"):
            minio.wait_health("http://127.0.0.1:9000", clock.sleep, clock, seconds=5,
                              get=lambda *a, **k: (503, {}, b""))


class MainTest(unittest.TestCase):
    def setUp(self):
        pin_test_binary()
        self.addCleanup(unpin)
        self.dir = pathlib.Path(tempfile.mkdtemp(prefix="elzoo-minio-main-"))
        self.addCleanup(shutil.rmtree, self.dir, True)
        self.env = {"RUNNER_TEMP": str(self.dir), "GITHUB_ENV": str(self.dir / "env"), "GITHUB_OUTPUT": str(self.dir / "out"),
                    "GITHUB_TOKEN": "job-token", "PATH": "/usr/bin:/bin"}
        self.lines = []
        self.clock = Clock()

    def run_main(self, net=None, check=lambda *a: None, popen=None, **kw):
        net = net or FakeNet()
        started = []

        class Process:
            pid = 4242

            def poll(self):
                return None

        def fake_popen(argv, **kwargs):
            started.append((argv, kwargs))
            return Process()

        def get(url, headers, timeout=5):
            if "/minio/health/" in url:
                return 200, {}, b""
            return net.get(url, headers, timeout)
        code = minio.main(self.env, out=self.lines.append, get=get, sleep=self.clock.sleep, clock=self.clock,
                          popen=popen or fake_popen, check=check)
        return code, started, net

    def test_full_flow_exports_the_connection_and_never_prints_the_credentials(self):
        code, started, _net = self.run_main()
        self.assertEqual(0, code)
        exported = dict(line.split("=", 1) for line in (self.dir / "env").read_text().splitlines())
        self.assertEqual({"ELZOO_TEST_S3_URL", "ELZOO_TEST_S3_BUCKET", "ELZOO_TEST_S3_ACCESS_KEY_ID",
                          "ELZOO_TEST_S3_SECRET_ACCESS_KEY", "ELZOO_TEST_S3_REGION"}, set(exported))
        self.assertTrue(exported["ELZOO_TEST_S3_URL"].startswith("http://127.0.0.1:"))
        self.assertEqual(("elzoo-test", "us-east-1"), (exported["ELZOO_TEST_S3_BUCKET"], exported["ELZOO_TEST_S3_REGION"]))
        access, secret = exported["ELZOO_TEST_S3_ACCESS_KEY_ID"], exported["ELZOO_TEST_S3_SECRET_ACCESS_KEY"]
        self.assertGreaterEqual(len(secret), 32)
        # masks come first, and the values appear in no other output line
        self.assertIn(f"::add-mask::{access}", self.lines)
        self.assertIn(f"::add-mask::{secret}", self.lines)
        others = [l for l in self.lines if not l.startswith("::add-mask::")]
        self.assertFalse(any(access in l or secret in l for l in others))
        self.assertEqual("source=release-asset API\n", (self.dir / "out").read_text())
        argv, kwargs = started[0]
        self.assertEqual(["server"], argv[1:2])
        self.assertTrue(all("127.0.0.1" in a for a in argv if a.startswith("--") is False and ":" in a and "/" not in a))
        self.assertEqual("127.0.0.1", argv[argv.index("--address") + 1].split(":")[0])
        self.assertEqual("127.0.0.1", argv[argv.index("--console-address") + 1].split(":")[0])
        self.assertEqual(access, kwargs["env"]["MINIO_ROOT_USER"])
        self.assertTrue(kwargs["start_new_session"])
        self.assertNotIn("GITHUB_TOKEN", kwargs["env"])   # the job token never reaches the server
        self.assertTrue((self.dir / "elzoo-minio" / "data" / "elzoo-test").is_dir())   # the bucket exists
        self.assertEqual(0o700, (self.dir / "elzoo-minio" / "minio").stat().st_mode & 0o777)

    def test_credentials_differ_between_runs(self):
        self.run_main()
        first = (self.dir / "env").read_text()
        (self.dir / "env").unlink()
        shutil.rmtree(self.dir / "elzoo-minio")
        self.run_main()
        self.assertNotEqual(first, (self.dir / "env").read_text())

    def test_a_downloaded_binary_is_copied_to_the_cache_directory_a_cached_one_is_not_rewritten(self):
        self.run_main()
        self.assertEqual(BINARY, (self.dir / "elzoo-minio-cache" / "minio").read_bytes())
        shutil.rmtree(self.dir / "elzoo-minio")
        (self.dir / "env").unlink()
        (self.dir / "out").unlink()
        code, _started, net = self.run_main()
        self.assertEqual(0, code)
        self.assertEqual("source=cache\n", (self.dir / "out").read_text())
        self.assertEqual([], net.calls)

    def test_failures_return_one_print_an_error_and_export_nothing(self):
        # no source
        net = FakeNet(api=[(404, {}, b"")], browser=[(404, {}, b"")])
        code, started, _ = self.run_main(net)
        self.assertEqual(1, code)
        self.assertTrue(any(l.startswith("::error::ELZOO MINIO step failed") for l in self.lines))
        self.assertEqual([], started)
        self.assertFalse((self.dir / "env").exists())

    def test_bucket_check_failure_exports_nothing(self):
        def bad(base, access, secret):
            raise minio.Stop("signed HEAD of the bucket answered HTTP 403")
        code, _started, _ = self.run_main(check=bad)
        self.assertEqual(1, code)
        self.assertFalse((self.dir / "env").exists())

    def test_server_that_dies_stops_the_step(self):
        class Dead:
            pid = 1

            def poll(self):
                return 1
        code, _started, _ = self.run_main(popen=lambda argv, **kw: Dead())
        self.assertEqual(1, code)
        self.assertTrue(any("ended before" in l for l in self.lines))
        self.assertFalse((self.dir / "env").exists())

    def test_export_refuses_values_with_newlines(self):
        with self.assertRaises(minio.Stop):
            minio.export({"A": "x\nB=y"}, {"GITHUB_ENV": str(self.dir / "env")})
        self.assertFalse((self.dir / "env").exists())

    def test_free_port_prefers_the_default_and_falls_back(self):
        import socket
        with socket.socket() as taken:
            taken.bind(("127.0.0.1", 0))
            busy = taken.getsockname()[1]
            taken.listen()
            self.assertNotEqual(busy, minio.free_port(busy))


if __name__ == "__main__":
    unittest.main()
