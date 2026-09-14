# Docker runtime architecture

`proaudio_player_docker/dev` є integration layer між:

```text
proaudio-player-native/dev
                         +
proaudio-player-webui/dev
                         |
                         v
                Docker multi-stage build
```

Docker-репозиторій не дублює application code і не повинен реалізовувати власну версію audio policy або frontend build logic.

## Build boundaries

Native build contract:

```text
повний checkout submodule
        -> cargo build --locked --release
        -> proaudio-player-native
```

Builder має `libpulse-dev` і `pkg-config`, оскільки universal backend використовує `libpulse-binding`.

Web UI build contract:

```text
package.json + package-lock.json
        -> npm ci
        -> npm run build
        -> dist/
```

Runtime знає тільки про `dist/`, а не про `src/`, назви bundle-файлів, framework або CSS pipeline. Це дозволяє змінювати frontend без правок Dockerfile, доки Web UI зберігає стандартний build contract.

Git submodule зафіксовані на конкретних SHA для reproducible build. `.gitmodules` одночасно містить upstream branch, який використовується лише явною командою `sync-sources`.

## Runtime layout

```text
                         physical LAN
                              |
             +----------------+----------------+
             |                                 |
             v                                 |
+----------------------------+                 |
| proaudio-player            |                 |
| network_mode: host         |                 |
|                            |                 |
| native + Web UI            |<----------------+
| PipeWire / Pulse / WP      |
| MPD / AirPlay / Spotify    |
| D-Bus / Avahi              |
+-------------+--------------+
              |
              | shared Pulse Unix socket
              v
+----------------------------+
| dlna-worker                |
| Docker bridge only         |
| 169.254.253.1:49494        |
| gmediarender / GStreamer   |
+----------------------------+
```

Основний контейнер є control plane і LAN-facing appliance. Web UI віддається самим native daemon з `/usr/share/proaudio-player/webui`, тому API та frontend залишаються same-origin на порту 8080.

## Чому DLNA worker окремий

У universal backend `gmediarender` — decoder/AVTransport worker, а не другий LAN renderer. Native очікує приватний endpoint:

```text
http://169.254.253.1:49494/upnp/control/rendertransport1
```

Запуск `gmediarender` всередині host-network контейнера робив би його окремим UPnP device у LAN або змушував би покладатися на loopback, який не є переносимим libupnp interface.

Тому worker:

- має лише user-defined Docker bridge;
- отримує статичну адресу `169.254.253.1`;
- не публікує жодного Docker port;
- може завантажувати HTTP/HTTPS media через стандартний Docker NAT;
- передає PCM у `proaudio_player_music` через спільний `pipewire-pulse` Unix socket;
- не має `/dev/snd` і не керує hardware volume.

Основний контейнер використовує host network і тому бачить адресу worker через route до Docker bridge. SSDP worker залишається всередині bridge і не рекламується у фізичну LAN.

## Audio graph

Docker не має власної копії routing policy. Він встановлює безпосередньо з native submodule:

```text
/usr/libexec/proaudio-player/audio-buses.sh
/usr/libexec/proaudio-player/proaudio-player-output-watch
```

Graph contract:

```text
programme source -> MUSIC --+
                            +--> MASTER --> physical sink / PARKING
alert -----------> ALERT --+
```

Фіксовані graph links працюють на unity. Вибір physical output, hot-plug reconciliation, PARKING fallback і hardware-unity policy належать native scripts.

`up-test` просто запускає цей самий graph без `/dev/snd`; він природно завершується на `PARKING_SINK`. Окремого Docker test sink немає.

Hardware mode додає лише:

```text
/dev/snd
/run/udev:ro
```

Постійний вибір виходу зберігається в `/var/lib/proaudio-player-alert/audio-output.env`, що на host відповідає `docker-data/data/audio-output.env`.

## Process supervision

Supervisor всередині основного контейнера запускає:

1. system/session D-Bus;
2. PipeWire, pipewire-pulse, WirePlumber;
3. native audio buses;
4. native output watcher;
5. Avahi;
6. MPD, Shairport Sync, spotifyd;
7. `proaudio-player-native`.

DLNA worker не є Supervisor process основного контейнера — ним керує Docker Compose як окремим мінімальним service.

## Persistent and ephemeral state

Persistent bind mounts:

```text
docker-data/config -> /etc/proaudio-player-alert
docker-data/data   -> /var/lib/proaudio-player-alert
docker-data/music  -> /srv/music
```

Named volume:

```text
proaudio-runtime -> /run/proaudio-player
```

`proaudio-runtime` використовується лише для Pulse socket і ready-state між двома контейнерами. Основний entrypoint очищає його на старті, щоб stale socket/lock не переживав runtime restart.

## Source updates

```bash
./docker/proaudio-player-dockerctl sync-sources
./docker/proaudio-player-dockerctl revisions
```

`sync-sources` читає branch policy з `.gitmodules` і виконує `git submodule update --remote --checkout`. Це свідома операція розробника. Звичайний clone/build використовує gitlink SHA і не плаває за HEAD upstream-гілок.

## Verification

Статичні integration tests:

```bash
pytest -q
```

Runtime smoke test:

```bash
./docker/proaudio-player-dockerctl up-test
curl -fsS http://127.0.0.1:8080/api/v1/health
./docker/proaudio-player-dockerctl status
./docker/proaudio-player-dockerctl sinks
```

Для hardware acceptance додатково перевіряються output switching, USB hot-plug, MUSIC + ALERT і DLNA playback.
