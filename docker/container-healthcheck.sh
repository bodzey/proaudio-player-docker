#!/usr/bin/env bash
set -euo pipefail

is_true() {
    [[ "${1,,}" =~ ^(1|true|yes|on)$ ]]
}

service_is_up() {
    local service="$1"
    [[ "$(s6-svstat -u "/etc/proaudio-player/services/$service")" == "true" ]]
}

require_enabled_service() {
    local flag="$1" service="$2"
    if is_true "$flag"; then
        service_is_up "$service"
    fi
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
    session-dbus \
    pipewire \
    pipewire-pulse \
    wireplumber \
    audio-buses \
    audio-output-watch \
    avahi \
    native; do
    service_is_up "$service"
done

require_enabled_service "${ENABLE_MPD:-true}" mpd
require_enabled_service "${ENABLE_AIRPLAY:-true}" airplay
require_enabled_service "${ENABLE_DLNA:-true}" dlna
require_enabled_service "${ENABLE_SPOTIFY:-true}" spotify

if is_true "${HEALTHCHECK_HTTP:-true}"; then
    healthcheck_port="${HEALTHCHECK_PORT:-${PROAUDIO_HTTP_PORT:-5371}}"
    curl --fail --silent --show-error --max-time 3 \
        "http://127.0.0.1:${healthcheck_port}/api/v1/health" >/dev/null
fi
