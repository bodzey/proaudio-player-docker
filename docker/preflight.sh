#!/usr/bin/env bash
set -euo pipefail

required=(
    amixer
    busctl
    dbus-daemon
    gmediarender
    ip
    kill
    mpc
    mpd
    mpv
    pactl
    pipewire
    pipewire-pulse
    proaudio-player-native
    shairport-sync
    spotifyd
    supervisorctl
    wireplumber
)

for program in "${required[@]}"; do
    if ! command -v "$program" >/dev/null 2>&1; then
        echo "Обов'язкова команда відсутня в образі: $program" >&2
        exit 1
    fi
done

for asset in \
    /usr/share/proaudio-player/webui/index.html \
    /usr/share/proaudio-player/webui/static/app.js \
    /usr/share/proaudio-player/webui/static/app.css \
    /usr/share/proaudio-player/announcements/alarm_start.mp3 \
    /usr/share/proaudio-player/announcements/alarm_end.mp3 \
    /usr/share/proaudio-player/announcements/minute_silence.mp3; do
    [[ -f "$asset" ]] || {
        echo "Обов'язковий runtime asset відсутній: $asset" >&2
        exit 1
    }
done

proaudio-player-native --version >/dev/null
spotifyd --version >/dev/null
shairport-sync -V >/dev/null
