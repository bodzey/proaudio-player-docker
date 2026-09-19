#!/usr/bin/env bash
set -euo pipefail

required=(
    amixer
    busctl
    dbus-daemon
    gmediarender
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
    /usr/share/proaudio-player/webui/manifest.webmanifest \
    /usr/share/proaudio-player/announcements/alarm_start.mp3 \
    /usr/share/proaudio-player/announcements/alarm_end.mp3 \
    /usr/share/proaudio-player/announcements/minute_silence.mp3 \
    /usr/libexec/proaudio-player/audio-buses.sh \
    /usr/libexec/proaudio-player/proaudio-player-output-watch \
    /opt/proaudio-player/defaults/audio.env.example \
    /opt/proaudio-player/defaults/mpd.conf \
    /opt/proaudio-player/defaults/shairport-sync.conf \
    /opt/proaudio-player/defaults/spotifyd.conf; do
    [[ -f "$asset" ]] || {
        echo "Обов'язковий runtime asset відсутній: $asset" >&2
        exit 1
    }
done

if ! find /usr/share/proaudio-player/webui -mindepth 2 -type f -print -quit | grep -q .; then
    echo "Web UI build не містить зібраних asset-файлів." >&2
    exit 1
fi

proaudio-player-native --version >/dev/null
spotifyd --version >/dev/null
shairport-sync -V >/dev/null
