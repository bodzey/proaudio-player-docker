#!/usr/bin/env bash
set -euo pipefail

is_true() {
    [[ "${1,,}" =~ ^(1|true|yes|on)$ ]]
}

[[ -f "$XDG_RUNTIME_DIR/proaudio-player-ready" ]]
for sink in \
    proaudio_player_music \
    proaudio_player_alert \
    proaudio_player_master \
    proaudio_player_parking; do
    pactl get-sink-volume "$sink" >/dev/null
done

for service in \
    system-dbus \
    pipewire \
    pipewire-pulse \
    wireplumber \
    audio-buses \
    audio-output-watch \
    native; do
    [[ "$(s6-svstat -u "/etc/proaudio-player/services/$service")" == "true" ]]
done

if is_true "${ENABLE_DLNA:-true}"; then
    [[ "$(s6-svstat -u /etc/proaudio-player/services/dlna)" == "true" ]]
fi

if is_true "${HEALTHCHECK_HTTP:-true}"; then
    curl --fail --silent --show-error --max-time 3 \
        "http://127.0.0.1:${HEALTHCHECK_PORT:-5371}/api/v1/health" >/dev/null
fi
