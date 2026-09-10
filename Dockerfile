FROM rust:1.88-bookworm AS native-builder

WORKDIR /build/proaudio-player-native

COPY sources/proaudio-player-native/Cargo.toml sources/proaudio-player-native/Cargo.lock ./
COPY sources/proaudio-player-native/src ./src

RUN cargo build --locked --release \
    && strip target/release/proaudio-player-native


FROM rust:1.88-bookworm AS spotifyd-builder

ARG SPOTIFYD_VERSION=0.4.2

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
       libdbus-1-dev libpulse-dev libssl-dev pkg-config \
    && cargo install spotifyd --locked --version "${SPOTIFYD_VERSION}" \
       --no-default-features --features pulseaudio_backend,dbus_mpris \
       --root /spotifyd-install \
    && strip /spotifyd-install/bin/spotifyd \
    && rm -rf /var/lib/apt/lists/* /usr/local/cargo/registry /usr/local/cargo/git


FROM debian:trixie-slim AS runtime

ARG APP_VERSION=dev
ARG NATIVE_REVISION=unknown
ARG WEBUI_REVISION=unknown

LABEL org.opencontainers.image.title="ProAudio Player" \
      org.opencontainers.image.version="${APP_VERSION}" \
      org.opencontainers.image.revision="${NATIVE_REVISION}" \
      org.opencontainers.image.description="amd64 Docker runtime for ProAudio Player native dev"

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=Europe/Kyiv \
    HOME=/home/proaudio-player \
    XDG_STATE_HOME=/home/proaudio-player/.local/state \
    XDG_RUNTIME_DIR=/run/proaudio-player \
    PIPEWIRE_RUNTIME_DIR=/run/proaudio-player \
    PULSE_SERVER=unix:/run/proaudio-player/pulse/native \
    DBUS_SESSION_BUS_ADDRESS=unix:path=/run/proaudio-player/session-bus \
    PROAUDIO_WEBUI_DIR=/usr/share/proaudio-player/webui \
    HEALTHCHECK_PORT=8080

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       alsa-utils \
       avahi-daemon \
       bash \
       ca-certificates \
       curl \
       dbus \
       gmediarender \
       gstreamer1.0-libav \
       gstreamer1.0-plugins-good \
       gstreamer1.0-pulseaudio \
       iproute2 \
       libspa-0.2-modules \
       mpc \
       mpd \
       mpv \
       pipewire \
       pipewire-pulse \
       procps \
       pulseaudio-utils \
       shairport-sync \
       supervisor \
       systemd \
       tini \
       tzdata \
       util-linux \
       wireplumber \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --create-home --uid 1000 --shell /bin/bash proaudio-player \
    && usermod -a -G audio proaudio-player

WORKDIR /opt/proaudio-player

COPY --from=native-builder \
     /build/proaudio-player-native/target/release/proaudio-player-native \
     /usr/local/bin/proaudio-player-native
COPY --from=spotifyd-builder /spotifyd-install/bin/spotifyd /usr/local/bin/spotifyd

COPY sources/proaudio-player-native/config /opt/proaudio-player/defaults
COPY sources/proaudio-player-native/assets/announcements \
     /usr/share/proaudio-player/announcements
COPY sources/proaudio-player-native/scripts/audio-buses.sh \
     /opt/proaudio-player/scripts/audio-buses.sh

COPY sources/proaudio-player-webui/index.html \
     sources/proaudio-player-webui/manifest.webmanifest \
     sources/proaudio-player-webui/sw.js \
     /usr/share/proaudio-player/webui/
COPY sources/proaudio-player-webui/static /usr/share/proaudio-player/webui/static

COPY sources/proaudio-player-native/config/wireplumber/51-proaudio-soft-mixer.conf \
     /etc/wireplumber/wireplumber.conf.d/51-proaudio-soft-mixer.conf
COPY sources/proaudio-player-native/config/avahi/proaudio-linkplay.service \
     /etc/avahi/services/proaudio-linkplay.service

COPY docker/proaudio-player-mpris.conf /etc/dbus-1/system.d/proaudio-player-mpris.conf
COPY docker/supervisord.conf /etc/supervisor/conf.d/proaudio-player.conf
COPY docker/docker-entrypoint.sh \
     docker/discover-audio.sh \
     docker/run-audio-buses.sh \
     docker/watch-audio-output.sh \
     docker/run-service.sh \
     docker/container-healthcheck.sh \
     docker/preflight.sh \
     /usr/local/bin/

RUN chmod 0755 \
       /opt/proaudio-player/scripts/audio-buses.sh \
       /usr/local/bin/docker-entrypoint.sh \
       /usr/local/bin/discover-audio.sh \
       /usr/local/bin/run-audio-buses.sh \
       /usr/local/bin/watch-audio-output.sh \
       /usr/local/bin/run-service.sh \
       /usr/local/bin/container-healthcheck.sh \
       /usr/local/bin/preflight.sh \
    && mkdir -p \
       /etc/proaudio-player-alert \
       /var/lib/proaudio-player-alert/mpd/playlists \
       /srv/music \
       /run/proaudio-player \
       /run/shairport-sync \
       /home/proaudio-player/.local/state/wireplumber \
       /usr/share/proaudio-player/webui \
    && chown -R proaudio-player:proaudio-player \
       /home/proaudio-player \
       /var/lib/proaudio-player-alert \
       /srv/music \
       /run/proaudio-player \
       /run/shairport-sync

HEALTHCHECK --interval=30s --timeout=5s --start-period=45s --retries=3 \
    CMD ["/usr/local/bin/container-healthcheck.sh"]

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/docker-entrypoint.sh"]
