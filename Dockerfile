FROM rust:bookworm AS spotifyd-builder

ARG SPOTIFYD_VERSION=0.4.2

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
       libpulse-dev libssl-dev pkg-config \
    && cargo install spotifyd --locked --version "${SPOTIFYD_VERSION}" \
       --no-default-features --features pulseaudio_backend \
       --root /spotifyd-install \
    && strip /spotifyd-install/bin/spotifyd \
    && rm -rf /var/lib/apt/lists/* /usr/local/cargo/registry /usr/local/cargo/git

FROM debian:trixie-slim AS python-builder

ENV DEBIAN_FRONTEND=noninteractive
WORKDIR /opt/proaudio-player

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       ca-certificates python3 python3-venv \
    && rm -rf /var/lib/apt/lists/*

COPY sources/proaudio-player/pyproject.toml ./
COPY sources/proaudio-player/src ./src

RUN python3 -m venv /opt/proaudio-player/venv \
    && /opt/proaudio-player/venv/bin/pip install \
       --disable-pip-version-check --no-cache-dir /opt/proaudio-player

FROM debian:trixie-slim AS runtime

ARG APP_VERSION=dev
ARG PLAYER_REVISION=unknown

LABEL org.opencontainers.image.title="ProAudio Player" \
      org.opencontainers.image.version="${APP_VERSION}" \
      org.opencontainers.image.revision="${PLAYER_REVISION}" \
      org.opencontainers.image.description="Docker development and integration runtime for ProAudio Player"

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=Europe/Kyiv \
    HOME=/home/proaudio-player \
    XDG_STATE_HOME=/home/proaudio-player/.local/state \
    XDG_RUNTIME_DIR=/run/proaudio-player \
    PIPEWIRE_RUNTIME_DIR=/run/proaudio-player \
    PULSE_SERVER=unix:/run/proaudio-player/pulse/native \
    DBUS_SESSION_BUS_ADDRESS=unix:path=/run/proaudio-player/session-bus

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       avahi-daemon ca-certificates dbus gmediarender gstreamer1.0-pulseaudio \
       mpc mpd mpv pipewire pipewire-pulse pulseaudio-utils python3 \
       shairport-sync supervisor tini tzdata util-linux wireplumber \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --create-home --uid 1000 --shell /bin/bash proaudio-player \
    && usermod -a -G audio,dialout proaudio-player

WORKDIR /opt/proaudio-player

COPY --from=spotifyd-builder /spotifyd-install/bin/spotifyd /usr/local/bin/spotifyd
COPY --from=python-builder /opt/proaudio-player/venv /opt/proaudio-player/venv

COPY sources/proaudio-player/config /opt/proaudio-player/defaults
COPY sources/proaudio-player/src/proaudio_player_alert/default_media \
     /opt/proaudio-player/default-media
COPY sources/proaudio-player/scripts/audio-buses.sh /opt/proaudio-player/scripts/audio-buses.sh

COPY docker/supervisord.conf /etc/supervisor/conf.d/proaudio-player.conf
COPY docker/docker-entrypoint.sh docker/discover-audio.sh docker/run-audio-buses.sh \
     docker/run-service.sh docker/container-healthcheck.sh /usr/local/bin/

COPY sources/proaudio-player/config/wireplumber/51-proaudio-soft-mixer.conf \
     /etc/wireplumber/wireplumber.conf.d/51-proaudio-soft-mixer.conf

RUN chmod 0755 /opt/proaudio-player/scripts/audio-buses.sh \
       /usr/local/bin/docker-entrypoint.sh /usr/local/bin/run-audio-buses.sh \
       /usr/local/bin/run-service.sh /usr/local/bin/container-healthcheck.sh \
       /usr/local/bin/discover-audio.sh \
    && mkdir -p /etc/proaudio-player-alert \
       /var/lib/proaudio-player-alert/media \
       /var/lib/proaudio-player-alert/mpd/playlists \
       /srv/music /run/proaudio-player \
       /home/proaudio-player/.local/state/wireplumber \
    && chown -R proaudio-player:proaudio-player \
       /home/proaudio-player /var/lib/proaudio-player-alert \
       /srv/music /run/proaudio-player

HEALTHCHECK --interval=30s --timeout=5s --start-period=45s --retries=3 \
    CMD ["/usr/local/bin/container-healthcheck.sh"]

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/docker-entrypoint.sh"]
