# Docker runtime architecture

`proaudio_player_docker/dev` є адаптером між двома dev-репозиторіями та Linux amd64 host:

```text
proaudio-player-native/dev
          +
proaudio-player-webui/dev
          |
          v
    Docker multi-stage build
          |
          v
 Debian trixie amd64 runtime
          |
          +-- proaudio-player-native
          +-- MPD
          +-- spotifyd
          +-- Shairport Sync
          +-- gmediarender / GStreamer
          +-- PipeWire + pipewire-pulse + WirePlumber
          +-- system D-Bus + session D-Bus
          +-- Avahi
          |
          v
       ALSA / /dev/snd
```

## Чому один контейнер

Native control plane взаємодіє з media engines через Pulse/PipeWire sink-и, system D-Bus MPRIS, MPD protocol і локальний gmediarender AVTransport endpoint. Один контейнер з host networking зберігає той самий runtime contract, що й Buildroot firmware, без systemd як PID 1.

Supervisor запускає процеси в такому порядку:

1. system/session D-Bus;
2. PipeWire, pipewire-pulse, WirePlumber;
3. постійні music/alert audio buses;
4. watcher вибору фізичного виходу;
5. Avahi та media engines;
6. `proaudio-player-native`.

## Web UI

Web UI береться безпосередньо з `proaudio-player-webui/dev` і встановлюється в:

```text
/usr/share/proaudio-player/webui
```

Native daemon отримує:

```text
PROAUDIO_WEBUI_DIR=/usr/share/proaudio-player/webui
```

Тому один порт 8080 обслуговує і статичний UI, і `/api/v1`.

## Audio

Тестовий режим:

```bash
./docker/proaudio-player-dockerctl up-test
```

створює `proaudio_player_test_output` і не потребує `/dev/snd`.

Hardware mode:

```bash
./docker/proaudio-player-dockerctl up-hardware
```

додає:

```text
/dev/snd
/run/udev:ro
```

Native `audio-buses.sh` створює `proaudio_player_music` і `proaudio_player_alert` та loopback-и до фізичного sink.

Постійний вибір виходу зберігається в:

```text
/var/lib/proaudio-player-alert/audio-output.env
```

На host це:

```text
docker-data/data/audio-output.env
```

У Buildroot зміну цього файла ловить systemd path unit. У Docker ту саму функцію виконує `watch-audio-output.sh`.

## D-Bus / MPRIS

`spotifyd` збирається з:

```text
pulseaudio_backend,dbus_mpris
```

Shairport Sync і spotifyd публікують MPRIS на system bus. Docker image встановлює policy для користувача `proaudio-player`, тому native daemon може отримувати metadata і виконувати transport control через `busctl --system`.

## Persistent identity

Під час першого запуску створюється `docker-data/data/machine-id`, який монтується логічно через persistent data і копіюється в `/etc/machine-id`. Це стабілізує device identity, яку native використовує для UPnP/4STREAM UUID.

## Оновлення dev

```bash
./docker/proaudio-player-dockerctl sync-dev
./docker/proaudio-player-dockerctl revisions
```

`sync-dev` використовує `git submodule update --remote` для двох верхньорівневих submodule, у `.gitmodules` для яких задано `branch = dev`.

Після перевірки нових ревізій їх потрібно зафіксувати у Docker-репозиторії звичайним commit gitlink-ів.

## Перевірка

```bash
./docker/proaudio-player-dockerctl status
curl -fsS http://127.0.0.1:8080/api/v1/health
./docker/proaudio-player-dockerctl sinks
```

Healthcheck перевіряє PipeWire buses, критичні Supervisor services та versioned native health endpoint.
