#!/usr/bin/env bash

set -Eeuo pipefail

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd -- "${TEST_DIR}/.." && pwd)"

# shellcheck disable=SC1091
source "${PROJECT_DIR}/install.sh"

TESTS_RUN=0

pass() {
    TESTS_RUN=$((TESTS_RUN + 1))
    printf 'ok %d - %s\n' "$TESTS_RUN" "$1"
}

fail() {
    printf 'not ok %d - %s\n' "$((TESTS_RUN + 1))" "$1" >&2
    exit 1
}

assert_true() {
    local description="$1"
    shift
    if "$@"; then
        pass "$description"
    else
        fail "$description"
    fi
}

assert_false() {
    local description="$1"
    shift
    if "$@"; then
        fail "$description"
    else
        pass "$description"
    fi
}

assert_equals() {
    local description="$1"
    local expected="$2"
    local actual="$3"
    if [[ "$actual" == "$expected" ]]; then
        pass "$description"
    else
        printf 'expected: %s\nactual:   %s\n' "$expected" "$actual" >&2
        fail "$description"
    fi
}

assert_true "accepts the lowest port" is_valid_port 1
assert_true "accepts the highest port" is_valid_port 65535
assert_false "rejects port zero" is_valid_port 0
assert_false "rejects an oversized port" is_valid_port 65536
assert_false "rejects a non-numeric port" is_valid_port 44x

VALID_UUID="d0f6a483-51b3-44eb-94b6-1f5fc9272c81"
assert_true "accepts a UUID" is_valid_uuid "$VALID_UUID"
assert_false "rejects a malformed UUID" is_valid_uuid d0f6a483-51b3

assert_true "accepts a domain" validate_server_address server.example.cn
assert_true "accepts an IPv6 address" validate_server_address 2001:db8::1
assert_false "rejects an address containing a path" validate_server_address example.com/path
assert_false "rejects an address containing whitespace" validate_server_address "bad host"
assert_false "rejects an address containing a port" validate_server_address example.com:443
assert_false "rejects a reserved example address" validate_server_address example.com
assert_false "rejects an invalid IPv4 server address" validate_server_address 999.0.0.1
assert_true "validates a public IPv4 address" is_valid_ipv4 203.0.113.8
assert_false "rejects an out-of-range IPv4 address" is_valid_ipv4 999.0.0.1

VLESSENC_FIXTURE='Choose one Authentication to use, do not mix them.

Authentication: X25519, not Post-Quantum
"decryption": "mlkem768x25519plus.native.600s.x25519-private"
"encryption": "mlkem768x25519plus.native.0rtt.x25519-public"

Authentication: ML-KEM-768, Post-Quantum
"decryption": "mlkem768x25519plus.native.600s.mlkem-private"
"encryption": "mlkem768x25519plus.native.0rtt.mlkem-public"'

parse_vlessenc_output "$VLESSENC_FIXTURE" || fail "parses vlessenc output"
assert_equals \
    "selects the ML-KEM decryption value" \
    "mlkem768x25519plus.native.600s.mlkem-private" \
    "$VLESS_DECRYPTION"
assert_equals \
    "selects the ML-KEM encryption value" \
    "mlkem768x25519plus.native.0rtt.mlkem-public" \
    "$VLESS_ENCRYPTION"

if parse_vlessenc_output 'unexpected output'; then
    fail "rejects an unknown vlessenc format"
else
    pass "rejects an unknown vlessenc format"
fi

command -v jq >/dev/null 2>&1 || fail "jq is required for the test suite"

CONFIG_TEMP="$(mktemp)"
register_temp_file "$CONFIG_TEMP"
render_config \
    "$CONFIG_TEMP" \
    443 \
    "$VALID_UUID" \
    "mlkem768x25519plus.native.600s.private"

assert_equals \
    "renders the current users field" \
    "$VALID_UUID" \
    "$(jq -r '.inbounds[0].settings.users[0].id' "$CONFIG_TEMP")"
assert_equals \
    "does not render the removed clients field" \
    "false" \
    "$(jq 'has("clients")' < <(jq '.inbounds[0].settings' "$CONFIG_TEMP"))"
assert_equals \
    "renders a numeric port" \
    "number" \
    "$(jq -r '.inbounds[0].port | type' "$CONFIG_TEMP")"
assert_equals \
    "does not render TLS, SNI, or transport camouflage" \
    "false" \
    "$(jq '.inbounds[0] | has("streamSettings")' "$CONFIG_TEMP")"

XRAY_CONFIG_PATH="$CONFIG_TEMP"
assert_true "recognizes a current managed config" is_current_managed_config
read_current_config || fail "reads a current managed config"
assert_equals "reads the current UUID" "$VALID_UUID" "$CURRENT_UUID"

LEGACY_CONFIG_TEMP="$(mktemp)"
register_temp_file "$LEGACY_CONFIG_TEMP"
jq '
    .inbounds[0].settings.clients = .inbounds[0].settings.users
    | del(.inbounds[0].settings.users)
    | del(.inbounds[0].tag)
' "$CONFIG_TEMP" >"$LEGACY_CONFIG_TEMP"
XRAY_CONFIG_PATH="$LEGACY_CONFIG_TEMP"
assert_true "recognizes a legacy managed config" is_legacy_managed_config
read_current_config || fail "reads a legacy managed config"
assert_equals "reads a legacy clients UUID" "$VALID_UUID" "$CURRENT_UUID"

CUSTOM_CONFIG_TEMP="$(mktemp)"
register_temp_file "$CUSTOM_CONFIG_TEMP"
jq '.routing = {rules: []}' "$CONFIG_TEMP" >"$CUSTOM_CONFIG_TEMP"
XRAY_CONFIG_PATH="$CUSTOM_CONFIG_TEMP"
assert_false "does not claim a customized config" is_script_managed_config

EXPECTED_URL="vless://${VALID_UUID}@198.51.100.42:443?encryption=mlkem768x25519plus.native.0rtt.client&flow=xtls-rprx-vision&type=tcp&security=none#Test%20Node"
ACTUAL_URL="$(build_vless_url \
    198.51.100.42 \
    443 \
    "$VALID_UUID" \
    "mlkem768x25519plus.native.0rtt.client" \
    "Test Node")"
assert_equals "builds and escapes a VLESS share URL" "$EXPECTED_URL" "$ACTUAL_URL"

IPV6_URL="$(build_vless_url \
    2001:db8::1 \
    443 \
    "$VALID_UUID" \
    "mlkem768x25519plus.native.0rtt.client" \
    "IPv6")"
[[ "$IPV6_URL" == vless://*'@[2001:db8::1]:443?'* ]] || fail "wraps IPv6 in brackets"
pass "wraps IPv6 in brackets"

printf '1..%d\n' "$TESTS_RUN"
