#!/usr/bin/env bash
set -euo pipefail

flag_name="${1:?missing enable flag}"
wait_mode="${2:?missing wait mode}"
shift 2

if [[ "$flag_name" != "ALWAYS" ]]; then
    flag_value="${!flag_name:-true}"
    case "${flag_value,,}" in
        1|true|yes|on) ;;
        *)
            echo "$flag_name вимкнено; служба не запускається"
            exec sleep infinity
            ;;
    esac
fi

if [[ "$wait_mode" == "audio" ]]; then
    while [[ ! -f "$XDG_RUNTIME_DIR/proaudio-player-ready" ]] \
        || ! pactl get-sink-volume proaudio_player_music >/dev/null 2>&1; do
        sleep 1
    done
fi

exec "$@"
