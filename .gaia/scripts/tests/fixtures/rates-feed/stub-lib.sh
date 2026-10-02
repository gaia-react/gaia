# shellcheck shell=bash
# Local rates-feed stub for bats suites: a python3 (stdlib only) HTTP(S)
# server on 127.0.0.1, sourced by the suites that exercise the feed heal. The
# python source is a heredoc below because a tracked .py file would have no
# Code Audit Team owner.
#
# TLS uses a throwaway self-signed cert trusted through CURL_CA_BUNDLE. curl -q
# skips .curlrc but not that variable, so the lib under test keeps its pinned
# argv and the stub still verifies. The cert config uses a subjectAltName
# section, not `openssl req -addext`, which older LibreSSL lacks.
#
# The stub reads its mode and body from files in its own dir on every request,
# so a test switches behaviour between runs with rates_stub_set_mode. Modes:
# serve, status500, nonjson, nomodels, oversize, stall-handshake, stall-body.
#
# Every start function returns non-zero with one stderr line when python3 or
# openssl is missing or the stub fails to start. Suites start the stub through
# rates_stub_start_or_skip, never `rates_stub_start || skip`: bats reports a
# skip as `ok`, so that spelling turns a broken stub into a green run that never
# exercised the feed.

_RATES_STUB_PIDS=""

_rates_stub_python_source() {
  cat <<'PYEOF'
import http.server
import os
import socketserver
import ssl
import sys
import threading
import time

stub_dir, use_tls = sys.argv[1], sys.argv[2] == "tls"
lock = threading.Lock()
counter = [0]


def read(name, default=""):
    try:
        with open(os.path.join(stub_dir, name), "rb") as f:
            return f.read()
    except OSError:
        return default.encode()


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def setup(self):
        if use_tls:
            self.request.settimeout(10)
            self.request.do_handshake()
            self.request.settimeout(None)
        super().setup()

    def log_message(self, *args):
        pass

    def do_GET(self):
        with lock:
            counter[0] += 1
            n = counter[0]
            with open(os.path.join(stub_dir, "reqs"), "a") as f:
                f.write(self.requestline + "\n")
            with open(os.path.join(stub_dir, "hdrs"), "a") as f:
                for k, v in self.headers.items():
                    f.write("%d %s: %s\n" % (n, k, v))
        mode = read("mode", "serve").decode().strip()
        body = read("body", "{}")
        if mode == "stall-handshake":
            time.sleep(60)
            return
        if mode == "stall-body":
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", "100000")
            self.end_headers()
            self.wfile.write(b'{"models": ')
            self.wfile.flush()
            time.sleep(60)
            return
        if mode == "nonjson":
            body = b"this is not json\n"
        elif mode == "nomodels":
            body = b'{"cache_multipliers": {"read": 0.1}}\n'
        elif mode == "oversize":
            body = b'{"models": {}, "pad": "' + b"x" * 300000 + b'"}\n'
        status = 500 if mode == "status500" else 200
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)
        self.close_connection = True


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True


srv = Server(("127.0.0.1", 0), Handler)
if use_tls:
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(os.path.join(stub_dir, "cert.pem"), os.path.join(stub_dir, "key.pem"))
    srv.socket = ctx.wrap_socket(srv.socket, server_side=True, do_handshake_on_connect=False)
tmp = os.path.join(stub_dir, "port.tmp")
with open(tmp, "w") as f:
    f.write(str(srv.server_address[1]))
os.rename(tmp, os.path.join(stub_dir, "port"))
srv.serve_forever()
PYEOF
}

_rates_stub_need_tools() {
  if ! command -v python3 >/dev/null 2>&1; then
    echo "rates-stub: python3 is not available" >&2
    return 1
  fi
  if [[ "${1:-}" == "tls" ]] && ! command -v openssl >/dev/null 2>&1; then
    echo "rates-stub: openssl is not available" >&2
    return 1
  fi
  return 0
}

# Sets _RATES_STUB_PORT. Args: <stub_directory> <tls|plain> <mode> [body_file].
_rates_stub_launch() {
  local stub_directory="$1" kind="$2" mode="$3" body_file="${4:-}" i pid
  mkdir -p "$stub_directory" || return 1
  : >"$stub_directory/reqs"
  : >"$stub_directory/hdrs"
  printf '%s' "$mode" >"$stub_directory/mode"
  if [[ -n "$body_file" ]]; then
    cp "$body_file" "$stub_directory/body" || return 1
  else
    printf '{}' >"$stub_directory/body"
  fi
  if [[ "$kind" == "tls" ]]; then
    cat >"$stub_directory/cert.cnf" <<'CNF'
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = 127.0.0.1
[v3]
subjectAltName = IP:127.0.0.1
basicConstraints = critical, CA:TRUE
CNF
    openssl req -x509 -newkey rsa:2048 -nodes -days 2 \
      -keyout "$stub_directory/key.pem" -out "$stub_directory/cert.pem" -config "$stub_directory/cert.cnf" >/dev/null 2>&1 || {
      echo "rates-stub: openssl could not create the throwaway cert" >&2
      return 1
    }
  fi
  _rates_stub_python_source >"$stub_directory/server.py"
  # fd 3 is bats' result pipe; the server must not inherit it or the run hangs.
  python3 "$stub_directory/server.py" "$stub_directory" "$kind" >"$stub_directory/server.log" 2>&1 3>&- &
  pid=$!
  _RATES_STUB_PIDS="$_RATES_STUB_PIDS $pid"
  for ((i = 0; i < 100; i++)); do
    [[ -s "$stub_directory/port" ]] && break
    sleep 0.1
  done
  if [[ ! -s "$stub_directory/port" ]]; then
    echo "rates-stub: the server did not report a port" >&2
    return 1
  fi
  _RATES_STUB_PORT="$(cat "$stub_directory/port")"
  return 0
}

_rates_stub_root() {
  printf '%s' "${BATS_TEST_TMPDIR:-${TMPDIR:-/tmp}}"
}

rates_stub_start() {
  local mode="${1:-serve}" body_file="${2:-}"
  _rates_stub_need_tools tls || return 1
  RATES_STUB_DIRECTORY="$(_rates_stub_root)/rates-stub-tls"
  _rates_stub_launch "$RATES_STUB_DIRECTORY" tls "$mode" "$body_file" || return 1
  RATES_STUB_URL="https://127.0.0.1:${_RATES_STUB_PORT}/gaia-react/gaia/main/.gaia/scripts/token-rates.json"
  RATES_STUB_REQUESTS="$RATES_STUB_DIRECTORY/reqs"
  RATES_STUB_HEADERS="$RATES_STUB_DIRECTORY/hdrs"
  CURL_CA_BUNDLE="$RATES_STUB_DIRECTORY/cert.pem"
  export RATES_STUB_DIRECTORY RATES_STUB_URL RATES_STUB_REQUESTS RATES_STUB_HEADERS CURL_CA_BUNDLE
}

rates_stub_start_plain() {
  local body_file="${1:-}"
  _rates_stub_need_tools plain || return 1
  RATES_PLAIN_DIRECTORY="$(_rates_stub_root)/rates-stub-plain"
  _rates_stub_launch "$RATES_PLAIN_DIRECTORY" plain serve "$body_file" || return 1
  RATES_PLAIN_URL="http://127.0.0.1:${_RATES_STUB_PORT}/gaia-react/gaia/main/.gaia/scripts/token-rates.json"
  RATES_PLAIN_REQUESTS="$RATES_PLAIN_DIRECTORY/reqs"
  export RATES_PLAIN_DIRECTORY RATES_PLAIN_URL RATES_PLAIN_REQUESTS
}

# rates_stub_start_or_skip <tls|plain> [start args...]
#
# Skips the calling test only when a tool is absent off CI. On a CI runner a
# missing tool returns non-zero, because the job that runs the suite provides
# python3 and openssl, so their absence there is a broken leg rather than a
# maybe (the same argument .gaia/tests/hooks/helpers/require-node-typescript.sh
# makes, gaia-react/gaia#1748). A stub that fails to start with its tools present
# always returns non-zero, on CI or off it. `skip` comes from the sourcing bats
# suite.
rates_stub_start_or_skip() {
  local kind="$1"
  shift
  if ! _rates_stub_need_tools "$kind"; then
    if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
      echo "rates-stub: a required tool is missing on a CI runner; the feed tests would skip to green" >&2
      return 1
    fi
    skip "rates stub unavailable: a required tool (python3 or openssl) is missing"
  fi
  if [[ "$kind" == "tls" ]]; then
    rates_stub_start "$@"
  else
    rates_stub_start_plain "$@"
  fi
}

# An https URL on a port nothing listens on: bind port 0, read it, close it.
rates_stub_refuse_url() {
  local port
  port="$(python3 -c 'import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()')" || return 1
  printf 'https://127.0.0.1:%s/gaia-react/gaia/main/.gaia/scripts/token-rates.json' "$port"
}

rates_stub_count() {
  local request_count
  if [[ -n "${RATES_STUB_REQUESTS:-}" && -f "$RATES_STUB_REQUESTS" ]]; then
    request_count="$(wc -l <"$RATES_STUB_REQUESTS")"
    printf '%s' "$((request_count + 0))"
  else
    printf '0'
  fi
}

rates_stub_set_mode() {
  local mode="$1" body_file="${2:-}"
  [[ -n "${RATES_STUB_DIRECTORY:-}" ]] || return 1
  printf '%s' "$mode" >"$RATES_STUB_DIRECTORY/mode"
  if [[ -n "$body_file" ]]; then
    cp "$body_file" "$RATES_STUB_DIRECTORY/body" || return 1
  fi
}

rates_stub_stop() {
  local pid
  for pid in $_RATES_STUB_PIDS; do
    kill "$pid" >/dev/null 2>&1 || true
    wait "$pid" >/dev/null 2>&1 || true
  done
  _RATES_STUB_PIDS=""
  return 0
}
