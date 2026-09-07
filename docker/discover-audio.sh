#!/usr/bin/env bash
set -euo pipefail

AUDIO_USER=proaudio-player
RUNTIME_DIR=/run/proaudio-player-discovery
SESSION_BUS="$RUNTIME_DIR/session-bus"
PROCESS_IDS=()

cleanup() {
    if ((${#PROCESS_IDS[@]})); then
        kill "${PROCESS_IDS[@]}" >/dev/null 2>&1 || true
        wait "${PROCESS_IDS[@]}" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT INT TERM

install -d -o "$AUDIO_USER" -g "$AUDIO_USER" -m 0700 "$RUNTIME_DIR"
install -d -o "$AUDIO_USER" -g "$AUDIO_USER" -m 0750 \
    "/home/$AUDIO_USER/.local/state/wireplumber"

as_audio=(runuser -u "$AUDIO_USER" -- env \
    HOME="/home/$AUDIO_USER" \
    XDG_STATE_HOME="/home/$AUDIO_USER/.local/state" \
    XDG_RUNTIME_DIR="$RUNTIME_DIR" \
    PIPEWIRE_RUNTIME_DIR="$RUNTIME_DIR" \
    PULSE_SERVER="unix:$RUNTIME_DIR/pulse/native" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=$SESSION_BUS")

"${as_audio[@]}" dbus-daemon --session --nofork --nopidfile \
    --address="unix:path=$SESSION_BUS" >/tmp/proaudio-discovery-dbus.log 2>&1 &
PROCESS_IDS+=("$!")

for _ in {1..50}; do
    [[ -S "$SESSION_BUS" ]] && break
    sleep 0.1
done

"${as_audio[@]}" pipewire >/tmp/proaudio-discovery-pipewire.log 2>&1 &
PROCESS_IDS+=("$!")

for _ in {1..50}; do
    [[ -S "$RUNTIME_DIR/pipewire-0" ]] && break
    sleep 0.1
done

"${as_audio[@]}" pipewire-pulse >/tmp/proaudio-discovery-pulse.log 2>&1 &
PROCESS_IDS+=("$!")
"${as_audio[@]}" wireplumber >/tmp/proaudio-discovery-wireplumber.log 2>&1 &
PROCESS_IDS+=("$!")

for _ in {1..200}; do
    if "${as_audio[@]}" pactl info >/dev/null 2>&1; then
        sink_count="$("${as_audio[@]}" pactl list short sinks 2>/dev/null | \
            awk '$2 != "auto_null" { count++ } END { print count + 0 }')"
        ((sink_count > 0)) && break
    fi
    sleep 0.1
done

if ! "${as_audio[@]}" pactl info >/dev/null 2>&1; then
    echo "Не вдалося запустити тимчасовий PipeWire для пошуку аудіовиходів." >&2
    exit 1
fi

sleep 2

"${as_audio[@]}" pactl --format=json list sinks | python3 -c '
import json
import sys

sinks = json.load(sys.stdin)
found = 0
for sink in sinks:
    name = str(sink.get("name", ""))
    if not name or name == "auto_null" or name.startswith("proaudio_player_"):
        continue
    props = sink.get("properties") or {}
    description = str(
        props.get("device.description")
        or props.get("node.description")
        or props.get("device.product.name")
        or name
    ).replace("\t", " ").replace("\n", " ")
    print(f"SINK\t{name}\t{description}")
    found += 1
if not found:
    raise SystemExit(2)
' || {
    echo "PipeWire не виявив жодного фізичного виходу. Перевірте /dev/snd і /run/udev." >&2
    exit 1
}
