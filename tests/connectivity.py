"""Real loopback VLESS Encryption handshake; never installs or touches services."""
import contextlib
import http.server
import json
import os
from pathlib import Path
import socket
import struct
import subprocess
import tempfile
import threading
import time
import unittest
from urllib.parse import parse_qs, urlsplit

SCRIPT = Path(__file__).resolve().parents[1] / "install.sh"
PAYLOAD = b"vless-encryption-loopback-ok"


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Length", str(len(PAYLOAD)))
        self.end_headers()
        self.wfile.write(PAYLOAD)

    def log_message(self, *_):
        pass


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def read_exact(sock, size):
    result = b""
    while len(result) < size:
        part = sock.recv(size - len(result))
        if not part:
            raise ConnectionError("proxy closed the connection")
        result += part
    return result


def fetch_through_socks(port, target):
    with socket.create_connection(("127.0.0.1", port), timeout=5) as sock:
        sock.settimeout(5)
        sock.sendall(b"\x05\x01\x00")
        if read_exact(sock, 2) != b"\x05\x00":
            raise ConnectionError("SOCKS authentication failed")
        sock.sendall(b"\x05\x01\x00\x01\x7f\x00\x00\x01" + struct.pack("!H", target))
        reply = read_exact(sock, 4)
        if reply[:2] != b"\x05\x00":
            raise ConnectionError("SOCKS connection failed")
        size = {1: 4, 4: 16}.get(reply[3])
        if reply[3] == 3:
            size = read_exact(sock, 1)[0]
        if size is None:
            raise ConnectionError("invalid SOCKS address")
        read_exact(sock, size + 2)
        sock.sendall(b"GET / HTTP/1.0\r\nHost: localhost\r\n\r\n")
        data = b""
        while True:
            chunk = sock.recv(4096)
            if not chunk:
                break
            data += chunk
        if PAYLOAD not in data:
            raise ConnectionError("no loopback HTTP response through VLESS")
        return data


@unittest.skipUnless(os.environ.get("XRAY_TEST_BINARY"), "set XRAY_TEST_BINARY to an official core")
class ConnectivityTests(unittest.TestCase):
    @contextlib.contextmanager
    def core(self, binary, config, port, directory, name):
        path = directory / (name + ".json")
        path.write_text(json.dumps(config), encoding="utf-8")
        log_path = directory / (name + ".log")
        with log_path.open("wb") as log:
            process = subprocess.Popen([binary, "run", "-config", str(path)], stdout=log, stderr=log)
            try:
                deadline = time.monotonic() + 10
                while True:
                    if process.poll() is not None or time.monotonic() > deadline:
                        self.fail("core did not start: " + log_path.read_text(encoding="utf-8", errors="replace"))
                    try:
                        with socket.create_connection(("127.0.0.1", port), timeout=0.2):
                            break
                    except OSError:
                        time.sleep(0.05)
                yield
            finally:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)

    def check_connection(self, auth, appearance, wrong_uuid=False, old_fork=False):
        binary = str(Path(os.environ["XRAY_TEST_BINARY"]).resolve())
        with tempfile.TemporaryDirectory(prefix="vless-loopback-") as temporary:
            directory = Path(temporary)
            server_port, client_port = free_port(), free_port()
            fixture = directory / "fixture.sh"
            fixture.write_text(r'''set -euo pipefail
source "$INSTALL_SCRIPT"
XRAY_BIN="$XRAY_TEST_BINARY"
XRAY_CONFIG="$PWD/server.json"; ENCRYPTION_INFO="$PWD/encryption.info"
REALITY_INFO="$PWD/reality.info"; SUBSCRIPTION_INFO="$PWD/link"
SERVER_ADDRESS=''; SERVER_ADDRESS_INFO="$PWD/address"
printf '127.0.0.1\n' > "$SERVER_ADDRESS_INFO"
AUTH_MODE="$TEST_AUTH"; TRAFFIC_MODE="$TEST_APPEARANCE"
service_account() { printf '%s:%s\n' "$(id -u)" "$(id -g)"; }
pair=$(generate_encryption_pair); IFS='|' read -r dec enc <<< "$pair"
write_config "$TEST_PORT" 00000000-0000-4000-8000-000000000000 "$dec" "$enc" encryption
clear_rollback
if [ "$TEST_OLD_FORK" = true ]; then
    FORK_ENCRYPTION_INFO="$PWD/fork-encryption.info"
    UPSTREAM_ENCRYPTION_INFO="$ENCRYPTION_INFO"
    mv "$ENCRYPTION_INFO" "$FORK_ENCRYPTION_INFO"
    printf 'stale-root-key\n' > "$UPSTREAM_ENCRYPTION_INFO"
    select_client_state
fi
show_subscription > /dev/null
''', encoding="utf-8", newline="\n")
            environment = dict(os.environ, INSTALL_SCRIPT=SCRIPT.as_posix(),
                               XRAY_TEST_BINARY=Path(binary).as_posix(), TEST_AUTH=auth,
                               TEST_APPEARANCE=appearance, TEST_PORT=str(server_port),
                               TEST_OLD_FORK="true" if old_fork else "false")
            result = subprocess.run(["bash", fixture.as_posix()], cwd=directory, env=environment,
                                    capture_output=True, text=True, encoding="utf-8", timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            server = json.loads((directory / "server.json").read_text(encoding="utf-8"))
            server["inbounds"][0]["listen"] = "127.0.0.1"
            link = urlsplit((directory / "link").read_text(encoding="utf-8").strip())
            query = parse_qs(link.query)
            self.assertEqual(query["security"], ["none"])
            user = {"id": link.username, "encryption": query["encryption"][0], "flow": query["flow"][0]}
            if wrong_uuid:
                user["id"] = "00000000-0000-4000-8000-000000000001"
            client = {"log": {"loglevel": "warning"}, "inbounds": [{"listen": "127.0.0.1",
                      "port": client_port, "protocol": "socks", "settings": {"auth": "noauth"}}],
                      "outbounds": [{"protocol": "vless", "settings": {"vnext": [
                          {"address": link.hostname, "port": link.port, "users": [user]}]},
                          "streamSettings": {"network": "tcp", "security": query["security"][0]}}]}
            httpd = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
            thread = threading.Thread(target=httpd.serve_forever, daemon=True)
            thread.start()
            try:
                with self.core(binary, server, server_port, directory, "server"), \
                     self.core(binary, client, client_port, directory, "client"):
                    if wrong_uuid:
                        with self.assertRaises(OSError):
                            fetch_through_socks(client_port, httpd.server_port)
                    else:
                        self.assertIn(PAYLOAD, fetch_through_socks(client_port, httpd.server_port))
            finally:
                httpd.shutdown()
                httpd.server_close()
                thread.join(timeout=5)

    def test_supported_plain_modes(self):
        for auth in ("mlkem768", "x25519"):
            for appearance in ("native", "xorpub", "random"):
                with self.subTest(auth=auth, appearance=appearance):
                    self.check_connection(auth, appearance)

    def test_wrong_uuid_is_rejected(self):
        self.check_connection("mlkem768", "native", wrong_uuid=True)

    def test_old_fork_key_wins_over_stale_root_key(self):
        self.check_connection("mlkem768", "native", old_fork=True)


if __name__ == "__main__":
    unittest.main(verbosity=2)
