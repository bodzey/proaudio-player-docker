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

interface_flags() {
    local flags
    flags="$(ip -o link show dev "$1" 2>/dev/null | sed -n 's/^[^<]*<\([^>]*\)>.*/\1/p')"
    printf '%s' "$flags"
}

interface_ipv4() {
    ip -o -4 addr show dev "$1" scope global 2>/dev/null \
        | awk 'NR == 1 { split($4, address, "/"); print address[1] }'
}

interface_is_usable_for_dlna() {
    local flags address
    flags="$(interface_flags "$1")"
    address="$(interface_ipv4 "$1")"
    [[ -n "$address" ]] \
        && [[ ",$flags," == *,UP,* ]] \
        && [[ ",$flags," == *,MULTICAST,* ]]
}

select_dlna_interface() {
    local requested route candidate

    requested="${PROAUDIO_DLNA_INTERFACE:-}"
    if [[ -n "$requested" ]]; then
        if [[ "$requested" == "lo" ]] || ! interface_is_usable_for_dlna "$requested"; then
            echo "PROAUDIO_DLNA_INTERFACE=$requested не є активним multicast IPv4 інтерфейсом." >&2
            return 1
        fi
        printf '%s\n' "$requested"
        return 0
    fi

    route="$(ip -o -4 route get 239.255.255.250 2>/dev/null | head -n 1 || true)"
    candidate="$(awk '{ for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i + 1); exit } }' <<<"$route")"
    if [[ -n "$candidate" ]] && [[ "$candidate" != "lo" ]] && interface_is_usable_for_dlna "$candidate"; then
        printf '%s\n' "$candidate"
        return 0
    fi

    while IFS= read -r candidate; do
        [[ "$candidate" == "lo" ]] && continue
        if interface_is_usable_for_dlna "$candidate"; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done < <(ip -o -4 addr show scope global up 2>/dev/null | awk '{print $2}' | awk '!seen[$0]++')

    echo "Не знайдено активного multicast IPv4 інтерфейсу для DLNA." >&2
    return 1
}

if is_true "${ENABLE_DLNA:-true}"; then
    DLNA_PORT="${PROAUDIO_DLNA_PORT:-49494}"
    if ! [[ "$DLNA_PORT" =~ ^[0-9]+$ ]] || ((DLNA_PORT < 49152 || DLNA_PORT > 65535)); then
        echo "Некоректний PROAUDIO_DLNA_PORT: $DLNA_PORT (допустимо 49152..65535)" >&2
        exit 1
    fi

    PROAUDIO_DLNA_INTERFACE="$(select_dlna_interface)"
    DLNA_ADDRESS="$(interface_ipv4 "$PROAUDIO_DLNA_INTERFACE")"
    export PROAUDIO_DLNA_INTERFACE
    export PROAUDIO_DLNA_FRIENDLY_NAME="${PROAUDIO_DLNA_FRIENDLY_NAME:-ProAudio Player}"
    export PROAUDIO_DLNA_ENDPOINT="http://$DLNA_ADDRESS:$DLNA_PORT/upnp/control/rendertransport1"

    # libupnp deliberately rejects loopback interfaces. In Docker host-network
    # mode gmediarender therefore owns the public UPnP/DLNA protocol endpoint,
    # while native consumes it as the transport backend and remains the player
    # control plane for audio routing, source state and the Web API.
    export PROAUDIO_UPNP_PUBLIC=false
    echo "DLNA: gmediarender on $PROAUDIO_DLNA_INTERFACE ($DLNA_ADDRESS:$DLNA_PORT); native endpoint proxy disabled"
else
    unset PROAUDIO_DLNA_ENDPOINT
    unset PROAUDIO_DLNA_INTERFACE
    export PROAUDIO_UPNP_PUBLIC=false
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

configure_audio_device_access() {
    local node gid group_name

    node="$(find /dev/snd -maxdepth 1 -type c -print -quit 2>/dev/null || true)"
    if [[ -z "$node" ]]; then
        echo "AUDIO_MODE=hardware, але у /dev/snd немає ALSA device nodes." >&2
        return 1
    fi

    gid="$(stat -c '%g' "$node")"
    group_name="$(getent group "$gid" | cut -d: -f1 || true)"
    if [[ -z "$group_name" ]]; then
        group_name=proaudio-host-audio
        groupadd --gid "$gid" "$group_name"
    fi

    usermod -a -G "$group_name" proaudio-player
}

if [[ "${AUDIO_MODE:-null}" == "hardware" ]]; then
    if [[ ! -d /dev/snd ]]; then
        echo "AUDIO_MODE=hardware, але /dev/snd не передано в контейнер." >&2
        exit 1
    fi
    configure_audio_device_access
fi

/usr/local/bin/preflight.sh

exec /usr/bin/supervisord -c /etc/supervisor/conf.d/proaudio-player.conf
