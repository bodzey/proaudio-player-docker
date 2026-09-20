#!/usr/bin/env bash
set -euo pipefail

DATA_DIR="${PROAUDIO_DATA_DIR:-/var/lib/proaudio-player-alert}"
SERVICE_DIR=/etc/avahi/services
SERVICE_FILE="$SERVICE_DIR/proaudio-player.service"
DEVICE_ID_FILE="$DATA_DIR/device-id"
HTTP_PORT="${PROAUDIO_HTTP_PORT:-5371}"
API_MAJOR="${PROAUDIO_API_MAJOR:-1}"
DISPLAY_NAME="${PROAUDIO_DEVICE_NAME:-ProAudio Player}"
DISCOVERY_INTERFACE="${PROAUDIO_DISCOVERY_INTERFACE:-}"
AVAHI_CONF=/etc/avahi/avahi-daemon.conf

fail() {
    echo "ProAudio discovery: $*" >&2
    exit 1
}

normalize_uuid() {
    local value="${1,,}"
    if [[ ! "$value" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
        return 1
    fi
    printf '%s\n' "$value"
}

generate_uuid() {
    if [[ -r /proc/sys/kernel/random/uuid ]]; then
        cat /proc/sys/kernel/random/uuid
        return
    fi

    local compact
    compact="$(dbus-uuidgen)"
    [[ "$compact" =~ ^[0-9a-fA-F]{32}$ ]] || fail "cannot generate persistent device UUID"
    printf '%s-%s-%s-%s-%s\n'         "${compact:0:8}" "${compact:8:4}" "${compact:12:4}"         "${compact:16:4}" "${compact:20:12}"
}

xml_escape() {
    sed         -e 's/\&/\&amp;/g'         -e 's/</\&lt;/g'         -e 's/>/\&gt;/g'         <<<"$1"
}

[[ "$HTTP_PORT" =~ ^[0-9]+$ ]] && ((HTTP_PORT >= 1 && HTTP_PORT <= 65535))     || fail "invalid PROAUDIO_HTTP_PORT=$HTTP_PORT"

[[ "$API_MAJOR" =~ ^[1-9][0-9]*$ ]]     || fail "invalid PROAUDIO_API_MAJOR=$API_MAJOR"

[[ -n "$DISPLAY_NAME" ]] || fail "PROAUDIO_DEVICE_NAME must not be empty"
(("${#DISPLAY_NAME}" <= 63)) || fail "PROAUDIO_DEVICE_NAME must be at most 63 characters"
[[ "$DISCOVERY_INTERFACE" =~ ^[A-Za-z0-9_.:-]+$ ]] \
    || fail "invalid PROAUDIO_DISCOVERY_INTERFACE=$DISCOVERY_INTERFACE"

install -d -m 0755 "$DATA_DIR" "$SERVICE_DIR"

cat >"$AVAHI_CONF" <<EOF
[server]
use-ipv4=yes
use-ipv6=yes
allow-interfaces=$DISCOVERY_INTERFACE
enable-dbus=yes
disallow-other-stacks=no

[publish]
publish-hinfo=no
publish-workstation=no
EOF
chmod 0644 "$AVAHI_CONF"

configured_id="${PROAUDIO_DEVICE_ID:-}"
stored_id=""
if [[ -s "$DEVICE_ID_FILE" ]]; then
    stored_id="$(normalize_uuid "$(tr -d '[:space:]' <"$DEVICE_ID_FILE")")"         || fail "persistent device ID in $DEVICE_ID_FILE is invalid"
fi

if [[ -n "$configured_id" ]]; then
    configured_id="$(normalize_uuid "$configured_id")"         || fail "PROAUDIO_DEVICE_ID must be a canonical UUID"
    if [[ -n "$stored_id" && "$stored_id" != "$configured_id" ]]; then
        fail "PROAUDIO_DEVICE_ID does not match persistent $DEVICE_ID_FILE"
    fi
    device_id="$configured_id"
elif [[ -n "$stored_id" ]]; then
    device_id="$stored_id"
else
    device_id="$(normalize_uuid "$(generate_uuid)")"         || fail "generated device UUID is invalid"
fi

if [[ ! -s "$DEVICE_ID_FILE" ]]; then
    printf '%s\n' "$device_id" >"$DEVICE_ID_FILE"
    chmod 0644 "$DEVICE_ID_FILE"
fi

instance_name="$DISPLAY_NAME [${device_id:0:8}]"
escaped_instance="$(xml_escape "$instance_name")"
escaped_display="$(xml_escape "$DISPLAY_NAME")"

cat >"$SERVICE_FILE" <<EOF
<?xml version="1.0" standalone="no"?>
<!DOCTYPE service-group SYSTEM "avahi-service.dtd">
<service-group>
  <name replace-wildcards="no">$escaped_instance</name>
  <service>
    <type>_proaudio-player._tcp</type>
    <port>$HTTP_PORT</port>
    <txt-record>id=$device_id</txt-record>
    <txt-record>api=$API_MAJOR</txt-record>
    <txt-record>name=$escaped_display</txt-record>
  </service>
</service-group>
EOF
chmod 0644 "$SERVICE_FILE"

export PROAUDIO_DEVICE_ID="$device_id"
printf '%s\n' "$device_id" > /run/proaudio-player/device-id
chmod 0644 /run/proaudio-player/device-id

echo "ProAudio discovery: $DISPLAY_NAME id=$device_id api=$API_MAJOR port=$HTTP_PORT"
