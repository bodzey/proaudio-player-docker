#!/usr/bin/env bash
set -euo pipefail

CONFIG_DIR=/etc/proaudio-player-alert
DATA_DIR=/var/lib/proaudio-player-alert
RUNTIME_DIR=/run/proaudio-player
DEFAULTS_DIR=/opt/proaudio-player/defaults
HTTP_PORT="${PROAUDIO_HTTP_PORT:-5371}"

install -d -m 0755 "$CONFIG_DIR" /srv/music /run/dbus /var/lib/dbus
install -d -m 0750 "$DATA_DIR" "$DATA_DIR/mpd" "$DATA_DIR/mpd/playlists"
install -d -o proaudio-player -g proaudio-player -m 0700 \
    "$RUNTIME_DIR" /run/shairport-sync
install -d -o proaudio-player -g proaudio-player -m 0750 \
    /home/proaudio-player/.local/state/wireplumber

# /run/proaudio-player is ephemeral container runtime state.
# Never carry sockets or locks across starts.
find "$RUNTIME_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
install -d -o proaudio-player -g proaudio-player -m 0700 "$RUNTIME_DIR"

if [[ ! -f "$CONFIG_DIR/config.yaml" ]]; then
    install -m 0644 "$DEFAULTS_DIR/config.yaml.example" "$CONFIG_DIR/config.yaml"
fi
if [[ ! -f "$CONFIG_DIR/audio.env.override" ]]; then
    install -m 0644 /dev/null "$CONFIG_DIR/audio.env.override"
fi

# audio.env is generated from the exact native revision packaged in this image.
# Persistent Docker state carries only explicit KEY=VALUE overrides, so newly
# introduced native audio-policy keys appear automatically after a rebuild.
EFFECTIVE_AUDIO_ENV="$RUNTIME_DIR/audio.env"
AUDIO_OVERRIDE="$CONFIG_DIR/audio.env.override"
awk '
function assignment(line, key) {
    sub(/^[[:space:]]+/, "", line)
    sub(/[[:space:]]+$/, "", line)
    if (line == "" || line ~ /^#/) return ""
    if (line !~ /^[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=/) {
        print "Некоректний рядок audio.env.override: " line > "/dev/stderr"
        failed = 1
        return ""
    }
    key = line
    sub(/[[:space:]]*=.*/, "", key)
    return key
}
FNR == NR {
    key = assignment($0)
    if (key != "") {
        if (!(key in seen)) order[++count] = key
        seen[key] = 1
        value[key] = $0
    }
    next
}
{
    key = assignment($0)
    if (key != "") {
        if (!(key in seen)) order[++count] = key
        seen[key] = 1
        value[key] = $0
    }
}
END {
    if (failed) exit 2
    for (i = 1; i <= count; i++) print value[order[i]]
}
' "$DEFAULTS_DIR/audio.env.example" "$AUDIO_OVERRIDE" >"$EFFECTIVE_AUDIO_ENV.tmp"
mv -f -- "$EFFECTIVE_AUDIO_ENV.tmp" "$EFFECTIVE_AUDIO_ENV"
chmod 0644 "$EFFECTIVE_AUDIO_ENV"

if ! [[ "$HTTP_PORT" =~ ^[0-9]+$ ]] || ((HTTP_PORT < 1 || HTTP_PORT > 65535)); then
    echo "Некоректний PROAUDIO_HTTP_PORT: $HTTP_PORT" >&2
    exit 1
fi

is_true() {
    [[ "${1,,}" =~ ^(1|true|yes|on)$ ]]
}

route_interface() {
    local target="$1"
    ip -4 route get "$target" 2>/dev/null | awk '
        {
            for (i = 1; i <= NF; i++) {
                if ($i == "dev" && (i + 1) <= NF) {
                    print $(i + 1)
                    exit
                }
            }
        }
    '
}

detect_lan_interface() {
    local requested="${PROAUDIO_LAN_INTERFACE:-}"
    if [[ -n "$requested" ]]; then
        ip link show dev "$requested" >/dev/null 2>&1 || {
            echo "PROAUDIO_LAN_INTERFACE не існує: $requested" >&2
            return 1
        }
        printf '%s\n' "$requested"
        return 0
    fi

    local interface
    interface="$(route_interface 239.255.255.250)"
    if [[ -z "$interface" || "$interface" == "lo" ]]; then
        interface="$(route_interface 1.1.1.1)"
    fi
    if [[ -z "$interface" || "$interface" == "lo" ]]; then
        interface="$(ip -4 -o addr show scope global 2>/dev/null | awk '$2 != "lo" { print $2; exit }')"
    fi

    [[ -n "$interface" && "$interface" != "lo" ]] || return 1
    ip link show dev "$interface" >/dev/null 2>&1 || return 1
    printf '%s\n' "$interface"
}

detect_interface_ipv4() {
    local interface="$1"
    ip -4 -o addr show dev "$interface" scope global 2>/dev/null         | awk '{ split($4, a, "/"); print a[1]; exit }'
}

export PROAUDIO_UPNP_PUBLIC=false
if is_true "${ENABLE_DLNA:-true}"; then
    DLNA_INTERFACE="$(detect_lan_interface || true)"
    DLNA_ADDRESS=""
    if [[ -n "$DLNA_INTERFACE" ]]; then
        DLNA_ADDRESS="$(detect_interface_ipv4 "$DLNA_INTERFACE")"
    fi

    if [[ -z "$DLNA_INTERFACE" || -z "$DLNA_ADDRESS" ]]; then
        echo "DLNA вимкнено: не знайдено придатного IPv4 LAN-інтерфейсу." >&2
        export ENABLE_DLNA=false
        unset PROAUDIO_DLNA_ENDPOINT
    else
        DLNA_PORT="${PROAUDIO_DLNA_PORT:-49494}"
        if ! [[ "$DLNA_PORT" =~ ^[0-9]+$ ]] || ((DLNA_PORT < 1024 || DLNA_PORT > 65535)); then
            echo "Некоректний PROAUDIO_DLNA_PORT: $DLNA_PORT" >&2
            exit 1
        fi
        export PROAUDIO_LAN_INTERFACE="$DLNA_INTERFACE"
        export PROAUDIO_DLNA_ENDPOINT="http://$DLNA_ADDRESS:$DLNA_PORT/upnp/control/rendertransport1"
        echo "DLNA renderer: interface=$DLNA_INTERFACE address=$DLNA_ADDRESS port=$DLNA_PORT"
    fi
fi

# The main container uses host networking for multicast/discovery, so Docker
# cannot publish host_port:container_port in the normal bridge-network sense.
# Keep the port override in the Docker adapter and apply it to the mounted
# native config before the control plane starts.
sed -i -E \
    "/^(api|web):[[:space:]]*$/,/^[^[:space:]]/ s/^([[:space:]]*port:[[:space:]]*)[0-9]+(.*)$/\\1${HTTP_PORT}\\2/" \
    "$CONFIG_DIR/config.yaml"

if ! sed -n -E \
    "/^(api|web):[[:space:]]*$/,/^[^[:space:]]/ p" "$CONFIG_DIR/config.yaml" \
    | grep -Eq "^[[:space:]]+port:[[:space:]]*${HTTP_PORT}([[:space:]]|$)"; then
    echo "Не вдалося встановити api.port=$HTTP_PORT у $CONFIG_DIR/config.yaml" >&2
    exit 1
fi

if [[ ! -f "$CONFIG_DIR/alerts-token" ]]; then
    install -m 0600 /dev/null "$CONFIG_DIR/alerts-token"
fi

if [[ ! -s "$DATA_DIR/machine-id" ]]; then
    dbus-uuidgen >"$DATA_DIR/machine-id"
fi
install -m 0444 "$DATA_DIR/machine-id" /etc/machine-id
ln -sfn /etc/machine-id /var/lib/dbus/machine-id

find "$DATA_DIR" -maxdepth 2 -name '*.pid' -delete

chown -R proaudio-player:proaudio-player \
    "$DATA_DIR" /srv/music "$RUNTIME_DIR" /run/shairport-sync \
    /home/proaudio-player/.local/state/wireplumber
chown proaudio-player:proaudio-player \
    "$CONFIG_DIR/config.yaml" "$CONFIG_DIR/audio.env.override" \
    "$CONFIG_DIR/alerts-token" "$EFFECTIVE_AUDIO_ENV"
chmod 0600 "$CONFIG_DIR/alerts-token"

if [[ "${AUDIO_MODE:-null}" == "hardware" && ! -d /dev/snd ]]; then
    echo "AUDIO_MODE=hardware, але /dev/snd не передано в контейнер." >&2
    exit 1
fi

/usr/local/bin/preflight.sh

exec /usr/bin/supervisord -c /etc/supervisor/conf.d/proaudio-player.conf
