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

# /run/proaudio-player is a shared ephemeral coordination volume for the main
# runtime and the isolated DLNA worker. Never carry sockets/locks across starts.
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
