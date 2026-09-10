#!/usr/bin/env bash
set -euo pipefail

CONFIG_ENV=/etc/proaudio-player-alert/audio.env
OUTPUT_ENV=/var/lib/proaudio-player-alert/audio-output.env
READY_FILE="${XDG_RUNTIME_DIR:?XDG_RUNTIME_DIR is not set}/proaudio-player-ready"

while [[ ! -f "$READY_FILE" ]] || ! pactl info >/dev/null 2>&1; do
    sleep 1
done

last="$(cat "$OUTPUT_ENV" 2>/dev/null || true)"

while pactl info >/dev/null 2>&1; do
    current="$(cat "$OUTPUT_ENV" 2>/dev/null || true)"
    if [[ "$current" != "$last" ]]; then
        last="$current"

        if [[ "${AUDIO_MODE:-null}" == "null" ]]; then
            sleep 1
            continue
        fi

        set -a
        [[ -f "$CONFIG_ENV" ]] && source "$CONFIG_ENV"
        [[ -f "$OUTPUT_ENV" ]] && source "$OUTPUT_ENV"
        set +a

        if ! /opt/proaudio-player/scripts/audio-buses.sh switch; then
            echo "Не вдалося застосувати новий фізичний аудіовихід." >&2
        fi
    fi
    sleep 1
done

exit 1
