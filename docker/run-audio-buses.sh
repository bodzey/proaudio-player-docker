#!/usr/bin/env bash
set -euo pipefail

CONFIG_ENV="${PROAUDIO_AUDIO_ENV:-/run/proaudio-player/audio.env}"
OUTPUT_ENV=/var/lib/proaudio-player-alert/audio-output.env
BUS_SCRIPT=/usr/libexec/proaudio-player/audio-buses.sh
READY_FILE="${XDG_RUNTIME_DIR:?XDG_RUNTIME_DIR is not set}/proaudio-player-ready"
cleaned_up=0

cleanup() {
    ((cleaned_up == 0)) || return 0
    cleaned_up=1
    rm -f -- "$READY_FILE"
    "$BUS_SCRIPT" stop || true
}

shutdown() {
    trap - INT TERM
    cleanup
    exit 0
}

trap cleanup EXIT
trap shutdown INT TERM

while ! pactl info >/dev/null 2>&1; do
    sleep 1
done

set -a
[[ -f "$CONFIG_ENV" ]] && source "$CONFIG_ENV"
[[ -f "$OUTPUT_ENV" ]] && source "$OUTPUT_ENV"
set +a

"$BUS_SCRIPT" start
touch "$READY_FILE"

while pactl info >/dev/null 2>&1; do
    sleep 2
done

exit 1
