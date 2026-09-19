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

`s6-svscan` є process supervisor контейнера. Docker бачить один service/container, а внутрішні media engines залишаються окремими supervised-процесами без Python runtime.

## DLNA

Docker runtime використовує gmediarender як єдиний LAN-facing UPnP/DLNA MediaRenderer, а native підключається до нього як до transport backend:

```text
LAN / SSDP / SOAP
        |
        v
gmediarender -> proaudio_player_music
        ^
        |
        | PROAUDIO_DLNA_ENDPOINT
        |
proaudio-player-native
```

Це важливо для сумісності: libupnp, який використовує gmediarender, не приймає loopback interface у `UpnpInit2`, тому `--interface-name=lo` не є валідним transport isolation mechanism. Entry point тепер визначає активний multicast IPv4 interface через route до SSDP group `239.255.255.250`, перевіряє flags `UP` + `MULTICAST` і фактичну IPv4 адресу, після чого передає interface та endpoint обом процесам.

За потреби interface можна задати явно через `PROAUDIO_DLNA_INTERFACE`. Фіксованих `eth0`, `wlan0` або board-specific назв немає. У Docker native public UPnP вимкнений, щоб у LAN був рівно один renderer; native продовжує володіти audio routing, source arbitration, status aggregation та Web API.

Так немає sidecar-container, приватної Docker subnet або hardware-specific network policy.

## Audio

Docker споживає routing policy безпосередньо з native checkout:

```text
programme source -> MUSIC --+
                            +--> MASTER --> physical output / PARKING
alert -----------> ALERT --+
```

Default Compose не передає audio hardware. Це дозволяє запускати image на CI, server VM або development host з PARKING sink.

`compose.hardware.yaml` — optional generic Linux audio adapter. Він bind-mount-ить `/dev/snd`, передає read-only `/run/udev` і дозволяє стандартний Linux ALSA character-device major `116:*`. Це важливо для hotplug: нові ALSA device nodes стають видимими вже запущеному container та не блокуються cgroup device policy. Конкретна плата чи DAC у Docker layer невідомі.

Entry point визначає GID фактичного ALSA device node та надає runtime-користувачу відповідну supplementary group всередині контейнера, не покладаючись на GID групи `audio` хоста. Native output watcher обробляє topology events і зміни persisted output selection, тому Web UI може перемикати доступні sinks без перезапуску container.

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
bash tests/contract.sh
```

Runtime:

```bash
./docker/proaudio-player-dockerctl up-test
curl -fsS http://127.0.0.1:5371/api/v1/health
./docker/proaudio-player-dockerctl status
```

Hardware acceptance є окремим optional test і не є build requirement для Docker image.
