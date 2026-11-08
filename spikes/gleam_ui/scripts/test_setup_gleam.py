#!/usr/bin/env python3
"""Tests for setup_gleam.py with a fake HTTP layer (no network, no real compiler)."""
import hashlib
import importlib.util
import http.client
import http.server
import io
import pathlib
import sys
import tarfile
import tempfile
import threading
import unittest
import unittest.mock
import urllib.error

sys.dont_write_bytecode = True  # keep the checkout clean: no __pycache__ next to the scripts

HERE = pathlib.Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("setup_gleam", HERE / "setup_gleam.py")
setup_gleam = importlib.util.module_from_spec(spec)
spec.loader.exec_module(setup_gleam)

KEY = ("Linux", "x86_64")


def archive(names=("gleam-v0/gleam",), content=b"#!/bin/sh\necho gleam test\n"):
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode="w:gz") as tar:
        for name in names:
            info = tarfile.TarInfo(name)
            info.size = len(content)
            tar.addfile(info, io.BytesIO(content))
    return buffer.getvalue()


class FakeHttp:
    """Answers the API URL with a redirect (or a direct body) and the storage URL with the archive."""

    def __init__(self, body, api=None, storage=None, location="https://objects.githubusercontent.com/signed?x=1"):
        self.body = body
        self.api_answers = list(api if api is not None else [(302, {"Location": location}, b"")])
        self.storage_answers = list(storage if storage is not None else [(200, {}, body)])
        self.calls = []
        self.sleeps = []

    def get(self, url, headers):
        self.calls.append((url, dict(headers)))
        if url.startswith(setup_gleam.API):
            answers = self.api_answers
        else:
            answers = self.storage_answers
        answer = answers.pop(0) if len(answers) > 1 else answers[0]
        if isinstance(answer, Exception):
            raise answer
        return answer

    def sleep(self, seconds):
        self.sleeps.append(seconds)


class SetupGleamTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temp.name)
        self.data = archive()
        target, asset_id, _size, _sha = setup_gleam.ASSETS[KEY]
        self.original = setup_gleam.ASSETS[KEY]
        setup_gleam.ASSETS[KEY] = (target, asset_id, len(self.data), hashlib.sha256(self.data).hexdigest())
        self.ran = []

    def tearDown(self):
        setup_gleam.ASSETS[KEY] = self.original
        self.temp.cleanup()

    def run_install(self, fake, token="job-token", key=KEY):
        return setup_gleam.install(self.root, key[0], key[1], token, get=fake.get, sleep=fake.sleep,
                                   run=lambda argv, check: self.ran.append((argv, check)))

    def test_pins_equal_the_reviewed_release_digests(self):
        # Digests and asset ids read from the GitHub API for v1.19.2 on 2026-11-08.
        pins = {name: (asset_id, size, sha) for name, asset_id, size, sha in
                (v for v in self.original_assets().values())}
        self.assertEqual((633423401, 10565692, "2ba2afb66ca9f6dcc01a4a6e9169b6942963bad6483bec9571ddc078cfe6f41f"),
                         pins["x86_64-unknown-linux-musl"])
        self.assertEqual((633423257, 10126116, "d1d1a9d53f6b317c0563a4806873c8ccace54291ead023373728af379402d4f1"),
                         pins["aarch64-unknown-linux-musl"])
        self.assertEqual((633423162, 9234148, "fa7c6113e162ab1d979f72e7dde3e907b87e4b30c518af178768e577d180324d"),
                         pins["aarch64-apple-darwin"])
        self.assertEqual((633423317, 9702221, "c578192530507b868c4a6c8cb7ad5d2ab0830890257f41036f17c82853f19d05"),
                         pins["x86_64-apple-darwin"])

    def original_assets(self):
        assets = dict(setup_gleam.ASSETS)
        assets[KEY] = self.original
        return assets

    def test_install_through_redirect_and_token_only_to_api(self):
        fake = FakeHttp(self.data)
        binary = self.run_install(fake)
        self.assertEqual(self.root / ".tools" / "gleam", binary)
        self.assertEqual(b"#!/bin/sh\necho gleam test\n", binary.read_bytes())
        self.assertTrue(binary.stat().st_mode & 0o111)
        self.assertEqual(2, len(fake.calls))
        api_url, api_headers = fake.calls[0]
        self.assertEqual(setup_gleam.API + str(setup_gleam.ASSETS[KEY][1]), api_url)
        self.assertEqual("application/octet-stream", api_headers["Accept"])
        self.assertEqual("Bearer job-token", api_headers["Authorization"])
        storage_url, storage_headers = fake.calls[1]
        self.assertTrue(storage_url.startswith("https://objects.githubusercontent.com/"))
        self.assertNotIn("Authorization", storage_headers)
        self.assertEqual([([binary, "--version"], True)], self.ran)

    def test_no_token_sends_no_authorization(self):
        fake = FakeHttp(self.data)
        self.run_install(fake, token=None)
        self.assertNotIn("Authorization", fake.calls[0][1])

    def test_direct_200_from_api_is_accepted(self):
        fake = FakeHttp(self.data, api=[(200, {}, self.data)])
        self.run_install(fake)
        self.assertEqual(1, len(fake.calls))

    def test_checksum_mismatch_fails_closed(self):
        other = archive(content=b"different")
        fake = FakeHttp(other, storage=[(200, {}, other + b"")])
        target, asset_id, _size, sha = setup_gleam.ASSETS[KEY]
        setup_gleam.ASSETS[KEY] = (target, asset_id, len(other), sha)  # size fits, hash does not
        with self.assertRaisesRegex(SystemExit, "checksum mismatch"):
            self.run_install(fake)
        self.assertFalse((self.root / ".tools" / "gleam").exists())

    def test_size_mismatch_fails_closed(self):
        fake = FakeHttp(self.data, storage=[(200, {}, self.data + b"x")])
        with self.assertRaisesRegex(SystemExit, "size mismatch"):
            self.run_install(fake)
        self.assertFalse((self.root / ".tools" / "gleam").exists())

    def test_504_then_success_retries_with_backoff(self):
        fake = FakeHttp(self.data, storage=[(504, {}, b""), (504, {}, b""), (200, {}, self.data)])
        self.run_install(fake)
        self.assertEqual([2, 4], fake.sleeps)

    def test_500_is_retried_like_the_gateway_errors(self):
        fake = FakeHttp(self.data, api=[(500, {}, b""), (500, {}, b""), (302, {"Location": "https://objects.githubusercontent.com/x"}, b"")])
        self.run_install(fake)
        self.assertEqual([2, 4], fake.sleeps)

    def test_three_504_fail_closed(self):
        fake = FakeHttp(self.data, storage=[(504, {}, b"")])
        with self.assertRaisesRegex(SystemExit, "HTTP 504"):
            self.run_install(fake)
        self.assertEqual([2, 4], fake.sleeps)
        self.assertFalse((self.root / ".tools" / "gleam").exists())

    def test_other_http_errors_do_not_retry(self):
        for status in (401, 403, 404, 429):
            with self.subTest(status=status):
                fake = FakeHttp(self.data, api=[(status, {}, b"")])
                with self.assertRaisesRegex(SystemExit, f"HTTP {status}"):
                    self.run_install(fake)
                self.assertEqual([], fake.sleeps)
                self.assertEqual(1, len(fake.calls))

    def test_unexpected_redirect_hosts_refused(self):
        for location in ("https://evil.example/signed", "http://objects.githubusercontent.com/x",
                         "https://githubusercontent.com.evil.example/x", "https://evilgithub.com/x",
                         "https://github.com.evil.example/x", "ftp://github.com/x", ""):
            with self.subTest(location=location):
                fake = FakeHttp(self.data, api=[(302, {"Location": location}, b"")])
                with self.assertRaisesRegex(SystemExit, "unexpected host"):
                    self.run_install(fake)
                self.assertEqual(1, len(fake.calls))  # nothing was fetched from the refused host

    def test_allowed_redirect_hosts(self):
        for location in ("https://objects.githubusercontent.com/a", "https://release-assets.githubusercontent.com/a",
                         "https://github.com/a", "https://api.github.com/a"):
            with self.subTest(location=location):
                fake = FakeHttp(self.data, api=[(302, {"Location": location}, b"")])
                self.run_install(fake)

    def test_network_errors_fail_closed(self):
        for error in (urllib.error.URLError("unreachable"), TimeoutError("slow"), OSError("reset")):
            with self.subTest(error=type(error).__name__):
                fake = FakeHttp(self.data, api=[error])
                with self.assertRaisesRegex(SystemExit, "download failed"):
                    self.run_install(fake)

    def test_archive_must_hold_exactly_one_compiler(self):
        for names in ((), ("a/gleam", "b/gleam"), ("a/notgleam",)):
            with self.subTest(names=names):
                data = archive(names=names)
                target, asset_id, _size, _sha = setup_gleam.ASSETS[KEY]
                setup_gleam.ASSETS[KEY] = (target, asset_id, len(data), hashlib.sha256(data).hexdigest())
                fake = FakeHttp(data)
                with self.assertRaisesRegex(SystemExit, "exactly one compiler"):
                    self.run_install(fake)

    def test_unsupported_platform_refused_before_any_request(self):
        fake = FakeHttp(self.data)
        with self.assertRaisesRegex(SystemExit, "Unsupported"):
            self.run_install(fake, key=("Windows", "AMD64"))
        self.assertEqual([], fake.calls)

    def test_api_url_is_the_pinned_repository_asset_endpoint(self):
        self.assertEqual("https://api.github.com/repos/gleam-lang/gleam/releases/assets/", setup_gleam.API)

    def test_redirect_hosts_are_parsed_strictly(self):
        for location in ("https://evilgithubusercontent.com/x", "https://notgithub.com/x",
                         "https://github.com@evil.example/x", "https://user:pw@github.com/x",
                         "https://github.com:8443/x", "https://github.com:abc/x", "https://evil.example\\@github.com/x",
                         "https://evil.example%2f.github.com/x", "https://GITHUB.COM.evil.example/x",
                         "HTTP://github.com/x", "//github.com/x", "/relative/path", "https://github.com /x",
                         "https://exa\u0430mple.githubusercontent.com/x", "https://.github.com/x",
                         "https://github..com/x"):
            with self.subTest(location=location):
                self.assertFalse(setup_gleam.redirect_target_allowed(location))
        for location in ("https://github.com/x", "https://GitHub.com/x", "https://api.github.com:443/x",
                         "https://objects.githubusercontent.com/x?a=b&c=d",
                         # shape of a real signed release-asset URL: percent-encoded query values
                         "https://release-assets.githubusercontent.com/github-production-release-asset/1234/abc"
                         "?sp=r&sv=2018-11-09&sr=b&spr=https&se=2026-11-08T10%3A44%3A27Z&rscd=attachment%3B+filename%3Dgleam.tar.gz"
                         "&sig=ab%2Bcd%2Fef%3D&rsct=application%2Foctet-stream"):
            with self.subTest(location=location):
                self.assertTrue(setup_gleam.redirect_target_allowed(location))

    def test_http_exceptions_and_bad_urls_fail_closed(self):
        for error in (http.client.IncompleteRead(b"abc"), http.client.BadStatusLine("x"),
                      http.client.InvalidURL("bad"), ValueError("bad url")):
            with self.subTest(error=type(error).__name__):
                fake = FakeHttp(self.data, api=[error])
                with self.assertRaisesRegex(SystemExit, "download failed"):
                    self.run_install(fake)

    def test_unreadable_archive_fails_closed(self):
        data = b"not a gzip archive"
        target, asset_id, _size, _sha = setup_gleam.ASSETS[KEY]
        setup_gleam.ASSETS[KEY] = (target, asset_id, len(data), hashlib.sha256(data).hexdigest())
        with self.assertRaisesRegex(SystemExit, "could not be read"):
            self.run_install(FakeHttp(data))
        self.assertFalse((self.root / ".tools" / "gleam").exists())

    def test_http_get_passes_a_timeout(self):
        with unittest.mock.patch.object(setup_gleam._OPENER, "open") as opened:
            opened.return_value.__enter__.return_value.status = 200
            opened.return_value.__enter__.return_value.headers = {}
            opened.return_value.__enter__.return_value.read.return_value = b""
            setup_gleam.http_get("https://api.github.com/x", {})
        self.assertEqual(60, opened.call_args.kwargs["timeout"])

    def test_http_get_does_not_follow_a_redirect_and_sends_no_request_to_the_target(self):
        # Real sockets on loopback: server A redirects to server B; the opener must stop at A.
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
            status, headers, body = setup_gleam.http_get(
                f"http://127.0.0.1:{first.server_port}/asset", {"Authorization": "Bearer secret-token"})
        finally:
            for server in (first, target):
                server.shutdown()
                server.server_close()
        self.assertEqual(302, status)
        self.assertTrue(headers["Location"].endswith("/signed"))
        self.assertEqual(1, len(seen["a"]))
        self.assertEqual("Bearer secret-token", seen["a"][0]["Authorization"])
        self.assertEqual([], seen["b"])  # the redirect target was never contacted

    def test_redirect_handler_never_follows(self):
        handler = setup_gleam._NoRedirect()
        self.assertIsNone(handler.redirect_request(None, None, 302, "Found", {}, "https://example.invalid/"))


if __name__ == "__main__":
    unittest.main()
