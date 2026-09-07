#!/usr/bin/env bash
set -euo pipefail

CONFIG_DIR=/etc/proaudio-player-alert
DATA_DIR=/var/lib/proaudio-player-alert
RUNTIME_DIR=/run/proaudio-player
DEFAULTS_DIR=/opt/proaudio-player/defaults
DEFAULT_MEDIA_DIR=/opt/proaudio-player/default-media

install -d -m 0755 "$CONFIG_DIR" /srv/music
install -d -m 0750 "$DATA_DIR" "$DATA_DIR/media" "$DATA_DIR/mpd" \
    "$DATA_DIR/mpd/playlists"
install -d -m 0755 /run/dbus
install -d -o proaudio-player -g proaudio-player -m 0700 "$RUNTIME_DIR"

for config_name in config.yaml audio.env mpd.conf shairport-sync.conf spotifyd.conf; do
    if [[ ! -f "$CONFIG_DIR/$config_name" ]]; then
        source_name="$config_name"
        [[ "$config_name" == "config.yaml" ]] && source_name=config.yaml.example
        [[ "$config_name" == "audio.env" ]] && source_name=audio.env.example
        install -m 0644 "$DEFAULTS_DIR/$source_name" "$CONFIG_DIR/$config_name"
    fi
done

if [[ ! -f "$CONFIG_DIR/alerts-token" ]]; then
    install -m 0600 /dev/null "$CONFIG_DIR/alerts-token"
fi
if [[ -s "$CONFIG_DIR/alerts-token" ]]; then
    export ALERTS_API_TOKEN="$(tr -d '[:space:]' <"$CONFIG_DIR/alerts-token")"
fi

for media_name in alarm_start.mp3 alarm_end.mp3 minute_silence.mp3; do
    [[ -f "$DATA_DIR/media/$media_name" ]] || \
        install -m 0644 "$DEFAULT_MEDIA_DIR/$media_name" "$DATA_DIR/media/$media_name"
done

find "$DATA_DIR" -maxdepth 2 -name '*.pid' -delete
chown -R proaudio-player:proaudio-player "$DATA_DIR" /srv/music "$RUNTIME_DIR"
chmod 0600 "$CONFIG_DIR/alerts-token"

exec /usr/bin/supervisord -c /etc/supervisor/conf.d/proaudio-player.conf
