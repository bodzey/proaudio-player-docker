#!/usr/bin/env bash
set -euo pipefail

CONFIG_ENV=/etc/proaudio-player-alert/audio.env
OUTPUT_ENV=/var/lib/proaudio-player-alert/audio-output.env
TEST_MODULE=""

cleanup() {
    rm -f -- "$XDG_RUNTIME_DIR/proaudio-player-ready"
    /opt/proaudio-player/scripts/audio-buses.sh stop || true
    if [[ "$TEST_MODULE" =~ ^[0-9]+$ ]]; then
        pactl unload-module "$TEST_MODULE" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT INT TERM

while ! pactl info >/dev/null 2>&1; do
    sleep 1
done

set -a
[[ -f "$CONFIG_ENV" ]] && source "$CONFIG_ENV"
[[ -f "$OUTPUT_ENV" ]] && source "$OUTPUT_ENV"
set +a

if [[ "${AUDIO_MODE:-null}" == "null" ]]; then
    TEST_MODULE="$(pactl load-module module-null-sink \
        sink_name=proaudio_player_test_output \
        sink_properties=device.description=proaudio_player_test_output \
        rate="${SAMPLE_RATE:-48000}" channels=2)"
    export PHYSICAL_SINK=proaudio_player_test_output
fi

/opt/proaudio-player/scripts/audio-buses.sh start
touch "$XDG_RUNTIME_DIR/proaudio-player-ready"

while pactl info >/dev/null 2>&1; do
    sleep 2
done

exit 1
