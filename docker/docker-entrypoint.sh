#!/usr/bin/env bash
set -euo pipefail

CONFIG_DIR=/etc/proaudio-player-alert
DATA_DIR=/var/lib/proaudio-player-alert
RUNTIME_DIR=/run/proaudio-player
DEFAULTS_DIR=/opt/proaudio-player/defaults

install -d -m 0755 "$CONFIG_DIR" /srv/music /run/dbus /var/lib/dbus
install -d -m 0750 "$DATA_DIR" "$DATA_DIR/mpd" "$DATA_DIR/mpd/playlists"
install -d -o proaudio-player -g proaudio-player -m 0700 \
    "$RUNTIME_DIR" /run/shairport-sync
install -d -o proaudio-player -g proaudio-player -m 0750 \
    /home/proaudio-player/.local/state/wireplumber

# /run/proaudio-player is a shared ephemeral coordination volume for the main
# runtime and the isolated DLNA worker. Never carry sockets/locks across starts.
find "$RUNTIME_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
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

if [[ ! -s "$DATA_DIR/machine-id" ]]; then
    dbus-uuidgen >"$DATA_DIR/machine-id"
fi
install -m 0444 "$DATA_DIR/machine-id" /etc/machine-id
ln -sfn /etc/machine-id /var/lib/dbus/machine-id

find "$DATA_DIR" -maxdepth 2 -name '*.pid' -delete

chown -R proaudio-player:proaudio-player \
    "$DATA_DIR" /srv/music "$RUNTIME_DIR" /run/shairport-sync \
    /home/proaudio-player/.local/state/wireplumber
chown proaudio-player:proaudio-player \
    "$CONFIG_DIR/config.yaml" "$CONFIG_DIR/audio.env" \
    "$CONFIG_DIR/mpd.conf" "$CONFIG_DIR/shairport-sync.conf" \
    "$CONFIG_DIR/spotifyd.conf" "$CONFIG_DIR/alerts-token"
chmod 0600 "$CONFIG_DIR/alerts-token"

if [[ "${AUDIO_MODE:-null}" == "hardware" && ! -d /dev/snd ]]; then
    echo "AUDIO_MODE=hardware, але /dev/snd не передано в контейнер." >&2
    exit 1
fi

/usr/local/bin/preflight.sh

exec /usr/bin/supervisord -c /etc/supervisor/conf.d/proaudio-player.conf
