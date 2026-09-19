#!/usr/bin/env bash
set -euo pipefail

port="${PROAUDIO_DLNA_PORT:-49494}"
interface="${PROAUDIO_DLNA_INTERFACE:-}"
friendly_name="${PROAUDIO_DLNA_FRIENDLY_NAME:-ProAudio Player}"

if ! [[ "$port" =~ ^[0-9]+$ ]] || ((port < 49152 || port > 65535)); then
    echo "Некоректний PROAUDIO_DLNA_PORT: $port (допустимо 49152..65535)" >&2
    exit 1
fi

if [[ -z "$interface" ]]; then
    echo "PROAUDIO_DLNA_INTERFACE не визначено runtime-адаптером." >&2
    exit 1
fi

exec /usr/bin/gmediarender \
    --interface-name="$interface" \
    --port="$port" \
    --friendly-name="$friendly_name" \
    --gstout-audiosink=pulsesink \
    --gstout-initial-volume-db=0.0 \
    --gstout-buffer-duration=0 \
    --mime-filter=audio
