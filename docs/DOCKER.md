# Docker runtime architecture

`proaudio-player-docker` збирає native control plane та WebUI в один Linux container. Репозиторій не дублює business logic і не визначає board-specific policy.

## Build graph

```text
proaudio-player-native checkout -- cargo build --release --locked --+
                                                                    |
proaudio-player-webui checkout -- npm ci && npm run build ----------+--> runtime image
                                                                    |
spotifyd source build ----------------------------------------------+
```

Compose не примушує `linux/amd64`. Builders і runtime використовують multi-architecture upstream images.

## Single-container runtime

```text
physical LAN
    |
    v
+------------------------------------------------+
| proaudio-player                                |
| network_mode: host                             |
|                                                |
| D-Bus                                          |
| PipeWire / pipewire-pulse / WirePlumber        |
| MUSIC + ALERT -> MASTER -> output / PARKING     |
| MPD                                            |
| Shairport Sync                                 |
| spotifyd                                       |
| gmediarender                                   |
| proaudio-player-native + WebUI                  |
+------------------------------------------------+
```

Supervisor є process supervisor контейнера. Docker бачить один service/container, а внутрішні media engines залишаються ізольованими процесами.

## DLNA

У container runtime gmediarender є єдиним public DLNA MediaRenderer.

Entry point:

1. читає optional `PROAUDIO_LAN_INTERFACE`;
2. інакше знаходить IPv4 interface за маршрутом до SSDP multicast, з generic route/address fallback;
3. визначає його global IPv4;
4. формує `PROAUDIO_DLNA_ENDPOINT=http://<address>:<port>/upnp/control/rendertransport1`;
5. вимикає native public UPnP advertisement через `PROAUDIO_UPNP_PUBLIC=false`;
6. Supervisor запускає gmediarender на тому самому interface.

Так немає ні sidecar-container, ні hardcoded `eth0`, ні приватної Docker subnet.

Якщо придатного IPv4 interface немає, DLNA вимикається для цього запуску, але player runtime продовжує працювати.

## Audio

Docker споживає routing policy безпосередньо з native checkout:

```text
programme source -> MUSIC --+
                            +--> MASTER --> physical output / PARKING
alert -----------> ALERT --+
```

Default Compose не передає audio hardware. Це дозволяє запускати image на CI, server VM або development host з PARKING sink.

`compose.hardware.yaml` — optional generic Linux audio adapter. Він передає лише `/dev/snd` та read-only `/run/udev`; конкретна плата чи DAC у Docker layer невідомі.

## Persistent state

Bind mounts:

```text
docker-data/config -> /etc/proaudio-player-alert
docker-data/data   -> /var/lib/proaudio-player-alert
docker-data/music  -> /srv/music
```

Ephemeral state:

```text
/run/proaudio-player
```

Shared runtime volume відсутній, оскільки container один.

## Source policy

`.gitmodules` задає `dev` для native та WebUI. Gitlinks є bootstrap revisions; `dockerctl sync-sources` оновлює working checkout перед build.

## Acceptance

Static:

```bash
docker compose config --quiet
pytest -q
```

Runtime:

```bash
./docker/proaudio-player-dockerctl up-test
curl -fsS http://127.0.0.1:5371/api/v1/health
./docker/proaudio-player-dockerctl status
```

Hardware acceptance є окремим optional test і не є build requirement для Docker image.
