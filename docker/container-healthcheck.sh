#!/usr/bin/env bash
set -euo pipefail

[[ -f "$XDG_RUNTIME_DIR/proaudio-player-ready" ]]
pactl get-sink-volume proaudio_player_music >/dev/null
pactl get-sink-volume proaudio_player_alert >/dev/null
supervisorctl -c /etc/supervisor/conf.d/proaudio-player.conf status alert-controller \
    | grep -q RUNNING
if [[ "${ENABLE_WEB:-true}" =~ ^(1|true|yes|on)$ ]]; then
    supervisorctl -c /etc/supervisor/conf.d/proaudio-player.conf status web \
        | grep -q RUNNING
fi
