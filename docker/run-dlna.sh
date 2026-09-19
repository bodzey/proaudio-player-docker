#!/usr/bin/env bash
set -euo pipefail

port="${PROAUDIO_DLNA_PORT:-49494}"

if ! [[ "$port" =~ ^[0-9]+$ ]] || ((port < 49152 || port > 65535)); then
    echo "Некоректний PROAUDIO_DLNA_PORT: $port (допустимо 49152..65535)" >&2
    exit 1
fi

exec /usr/bin/gmediarender \
    --interface-name=lo \
    --port="$port" \
    --friendly-name="ProAudio Player Transport" \
    --gstout-audiosink=pulsesink \
    --gstout-initial-volume-db=0.0 \
    --gstout-buffer-duration=0 \
    --mime-filter=audio
