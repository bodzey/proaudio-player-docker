#!/usr/bin/env bash
set -euo pipefail

is_true() {
    [[ "${1,,}" =~ ^(1|true|yes|on)$ ]]
}

[[ -f "$XDG_RUNTIME_DIR/proaudio-player-ready" ]]
pactl get-sink-volume proaudio_player_music >/dev/null
pactl get-sink-volume proaudio_player_alert >/dev/null

for service in system-dbus pipewire pipewire-pulse wireplumber audio-buses native; do
    supervisorctl -c /etc/supervisor/conf.d/proaudio-player.conf status "$service" \
        | grep -q RUNNING
done

if is_true "${HEALTHCHECK_HTTP:-true}"; then
    curl --fail --silent --show-error --max-time 3 \
        "http://127.0.0.1:${HEALTHCHECK_PORT:-8080}/api/v1/health" >/dev/null
fi
