FROM rust:1.88-bookworm AS native-builder

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
       libpulse-dev \
       pkg-config \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build/proaudio-player-native
COPY sources/proaudio-player-native/ ./

RUN cargo build --locked --release \
    && strip target/release/proaudio-player-native


FROM node:22-bookworm-slim AS webui-builder

WORKDIR /build/proaudio-player-webui
COPY sources/proaudio-player-webui/package.json \
     sources/proaudio-player-webui/package-lock.json ./
RUN npm ci --no-audit --no-fund

COPY sources/proaudio-player-webui/ ./
RUN npm run build


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
      io.proaudio.native.revision="${NATIVE_REVISION}" \
      io.proaudio.webui.revision="${WEBUI_REVISION}" \
      org.opencontainers.image.description="Portable Linux Docker runtime for ProAudio Player"

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=Europe/Kyiv \
    HOME=/home/proaudio-player \
    XDG_STATE_HOME=/home/proaudio-player/.local/state \
    XDG_RUNTIME_DIR=/run/proaudio-player \
    PIPEWIRE_RUNTIME_DIR=/run/proaudio-player \
    PULSE_SERVER=unix:/run/proaudio-player/pulse/native \
    DBUS_SESSION_BUS_ADDRESS=unix:path=/run/proaudio-player/session-bus \
    PROAUDIO_WEBUI_DIR=/usr/share/proaudio-player/webui \
    PROAUDIO_HTTP_PORT=5371 \
    HEALTHCHECK_PORT=5371

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
       s6 \
       systemd \
       tini \
       tzdata \
       util-linux \
       wireplumber \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --create-home --uid 1000 --shell /bin/bash proaudio-player

WORKDIR /opt/proaudio-player

COPY --from=native-builder \
     /build/proaudio-player-native/target/release/proaudio-player-native \
     /usr/local/bin/proaudio-player-native
COPY --from=spotifyd-builder /spotifyd-install/bin/spotifyd /usr/local/bin/spotifyd
COPY --from=webui-builder /build/proaudio-player-webui/dist/ /usr/share/proaudio-player/webui/

COPY --from=native-builder /build/proaudio-player-native/config/ /opt/proaudio-player/defaults/
COPY --from=native-builder /build/proaudio-player-native/assets/announcements/ \
     /usr/share/proaudio-player/announcements/
COPY --from=native-builder /build/proaudio-player-native/scripts/audio-buses.sh \
     /usr/libexec/proaudio-player/audio-buses.sh
COPY --from=native-builder /build/proaudio-player-native/scripts/proaudio-player-output-watch \
     /usr/libexec/proaudio-player/proaudio-player-output-watch
COPY --from=native-builder /build/proaudio-player-native/scripts/proaudio-player-audioctl \
     /usr/local/bin/proaudio-player-audioctl

COPY --from=native-builder /build/proaudio-player-native/config/wireplumber/ \
     /etc/wireplumber/wireplumber.conf.d/
COPY docker/50-proaudio-rt.conf /etc/pipewire/pipewire.conf.d/50-proaudio-rt.conf
COPY docker/50-proaudio-rt.conf /etc/pipewire/pipewire-pulse.conf.d/50-proaudio-rt.conf
COPY docker/proaudio-player-mpris.conf /etc/dbus-1/system.d/proaudio-player-mpris.conf
COPY docker/s6-service-run /usr/local/bin/s6-service-run
COPY docker/docker-entrypoint.sh \
     docker/discover-audio.sh \
     docker/run-audio-buses.sh \
     docker/run-output-watch.sh \
     docker/run-dlna.sh \
     docker/run-service.sh \
     docker/container-healthcheck.sh \
     docker/configure-discovery.sh \
     docker/preflight.sh \
     /usr/local/bin/

RUN chmod 0755 \
       /usr/libexec/proaudio-player/audio-buses.sh \
       /usr/libexec/proaudio-player/proaudio-player-output-watch \
       /usr/local/bin/proaudio-player-audioctl \
       /usr/local/bin/docker-entrypoint.sh \
       /usr/local/bin/discover-audio.sh \
       /usr/local/bin/run-audio-buses.sh \
       /usr/local/bin/run-output-watch.sh \
       /usr/local/bin/run-dlna.sh \
       /usr/local/bin/run-service.sh \
       /usr/local/bin/container-healthcheck.sh \
       /usr/local/bin/configure-discovery.sh \
       /usr/local/bin/preflight.sh \
       /usr/local/bin/s6-service-run \
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
       /run/shairport-sync \
    && install -d -m 0755 /etc/proaudio-player/services \
    && for service in \
       system-dbus session-dbus pipewire pipewire-pulse wireplumber \
       audio-buses audio-output-watch avahi mpd airplay dlna spotify native; do \
         install -d -m 0755 "/etc/proaudio-player/services/$service"; \
         ln -s /usr/local/bin/s6-service-run "/etc/proaudio-player/services/$service/run"; \
       done \
    && if dpkg-query -W -f='${Package}\n' \
         | grep -Eq '^(python([0-9.]|$|-)|libpython)'; then \
         echo "Python runtime dependency detected in final image" >&2; \
         exit 1; \
       fi

HEALTHCHECK --interval=30s --timeout=5s --start-period=45s --retries=3 \
    CMD ["/usr/local/bin/container-healthcheck.sh"]

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/docker-entrypoint.sh"]
