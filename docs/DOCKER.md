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

Public protocol ownership залишається у native control plane. gmediarender є внутрішнім transport/decoder worker у тому самому container:

```text
LAN / SSDP / SOAP
        |
        v
proaudio-player-native
        |
        | PROAUDIO_DLNA_ENDPOINT
        v
127.0.0.1:49494
        |
        v
gmediarender -> proaudio_player_music
```

Entry point валідовує `PROAUDIO_DLNA_PORT`, задає loopback endpoint і вмикає native public UPnP лише коли `ENABLE_DLNA=true`. gmediarender запускається з `--interface-name=lo`, тому transport worker не рекламується як другий LAN renderer і не залежить від назви чи адреси мережевого інтерфейсу хоста.

Так немає sidecar-container, приватної Docker subnet, hardcoded `eth0` або Docker-specific дублювання DLNA control plane.

## Audio

Docker споживає routing policy безпосередньо з native checkout:

```text
programme source -> MUSIC --+
                            +--> MASTER --> physical output / PARKING
alert -----------> ALERT --+
```

Default Compose не передає audio hardware. Це дозволяє запускати image на CI, server VM або development host з PARKING sink.

`compose.hardware.yaml` — optional generic Linux audio adapter. Він передає лише `/dev/snd` та read-only `/run/udev`; конкретна плата чи DAC у Docker layer невідомі. Entry point визначає GID фактичного ALSA device node та надає runtime-користувачу відповідну supplementary group всередині контейнера, не покладаючись на GID групи `audio` хоста.

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
