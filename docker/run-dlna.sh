#!/usr/bin/env bash
set -euo pipefail

interface="${PROAUDIO_LAN_INTERFACE:?PROAUDIO_LAN_INTERFACE is not set}"
port="${PROAUDIO_DLNA_PORT:-49494}"

if ! [[ "$port" =~ ^[0-9]+$ ]] || ((port < 1024 || port > 65535)); then
    echo "Некоректний PROAUDIO_DLNA_PORT: $port" >&2
    exit 1
fi

if ! ip link show dev "$interface" >/dev/null 2>&1; then
    echo "DLNA interface не існує: $interface" >&2
    exit 1
fi

exec /usr/bin/gmediarender     --interface-name="$interface"     --port="$port"     --friendly-name="ProAudio Player"     --gstout-audiosink=pulsesink     --gstout-initial-volume-db=0.0     --gstout-buffer-duration=0     --mime-filter=audio
