#!/usr/bin/env bash
set -euo pipefail

READY_FILE="${XDG_RUNTIME_DIR:?XDG_RUNTIME_DIR is not set}/proaudio-player-ready"
WATCHER=/usr/libexec/proaudio-player/proaudio-player-output-watch

# audio-buses owns initial graph construction. Starting the watcher before that
# transaction finishes can make AUTO policy react to transient WirePlumber sink
# states and rebuild the graph toward a different device. Wait for the committed
# graph, then let the watcher own hotplug/reconciliation for the rest of runtime.
until [[ -f "$READY_FILE" ]] && pactl info >/dev/null 2>&1; do
    sleep 0.2
done

exec "$WATCHER"
