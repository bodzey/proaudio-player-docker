#!/usr/bin/env bash
set -euo pipefail

is_true() {
    [[ "${1,,}" =~ ^(1|true|yes|on)$ ]]
}

if ! is_true "${ENABLE_DLNA:-true}"; then
    echo "DLNA worker вимкнено через ENABLE_DLNA=${ENABLE_DLNA:-false}."
    exec sleep infinity
fi

RUNTIME_DIR=/run/proaudio-player
READY_FILE="$RUNTIME_DIR/proaudio-player-ready"
PULSE_SOCKET="$RUNTIME_DIR/pulse/native"

while [[ ! -f "$READY_FILE" || ! -S "$PULSE_SOCKET" ]]; do
    sleep 1
done

exec /usr/bin/gmediarender \
    --interface-name=eth0 \
    --port=49494 \
    --friendly-name="ProAudio Player Transport" \
    --gstout-audiosink=pulsesink \
    --gstout-initial-volume-db=0.0 \
    --gstout-buffer-duration=0
