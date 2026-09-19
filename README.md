# ProAudio Player Docker

Універсальний Docker/Compose runtime для актуальних `dev`-гілок **ProAudio Player Native** та **Web UI**.

Docker-репозиторій є integration layer. Він не містить окремої реалізації player logic, audio routing або UI: native та WebUI підключені як Git submodule і збираються через їхні власні build contracts.

## Runtime model

`compose.yaml` запускає рівно один container:

```text
proaudio-player
```

Усередині нього Supervisor керує:

- system/session D-Bus;
- PipeWire, pipewire-pulse та WirePlumber;
- MUSIC / ALERT / MASTER bus runtime з native;
- output watcher;
- MPD;
- AirPlay через Shairport Sync;
- Spotify Connect через spotifyd;
- DLNA/UPnP через gmediarender;
- `proaudio-player-native`;
- Web UI, який віддає native daemon.

Окремого DLNA sidecar-контейнера немає. `dockerctl up-test` і `up-hardware` запускають Compose з `--remove-orphans`, тому старий sidecar від попередньої версії автоматично видаляється.

## Hardware neutrality

Docker runtime не містить Raspberry Pi, SoC, board name, конкретної звукової карти або фіксованої назви LAN-інтерфейсу.

Також Compose не задає `platform: linux/amd64`. Image збирається для архітектури Docker host/build platform; підтримка конкретної CPU-архітектури визначається доступністю upstream base images і залежностей, а не кодом цього репозиторію.

Стандартний `compose.yaml` не вимагає фізичного audio device. Без `/dev/snd` native audio graph використовує PARKING sink.

Опціональний `compose.hardware.yaml` є лише generic Linux ALSA passthrough:

```text
/dev/snd
/run/udev:ro
ALSA character devices major 116
```

`/dev/snd` передається як live bind mount, а cgroup дозволяє весь стандартний ALSA character-device major. Тому USB/PCI аудіопристрої, які з’являються після старту container, не потребують його перезапуску лише для появи нового device node. `/run/udev` передається read-only для актуальних device metadata.

Docker не знає модель DAC, USB VID/PID, Raspberry Pi або назву ALSA card. Під час старту контейнер читає фактичний GID переданого `/dev/snd` і додає runtime-користувача до відповідної групи всередині контейнера, тому збіг GID `audio` між різними Linux-хостами не потрібен.

## Network discovery

Основний container використовує `network_mode: host`, оскільки AirPlay, Avahi, Spotify Connect і native DLNA/UPnP використовують LAN multicast/discovery.

DLNA реалізований у тому самому container через gmediarender, а native використовує його як transport backend:

```text
LAN controller -> gmediarender -> MUSIC bus
                         ^
                         |
               proaudio-player-native
```

У Docker runtime саме gmediarender володіє зовнішнім UPnP/DLNA MediaRenderer endpoint. Це використовує повну UPnP eventing/control реалізацію libupnp та не дублює renderer у native. Native отримує адресу transport endpoint через `PROAUDIO_DLNA_ENDPOINT`, стежить за станом джерела та зберігає ownership над audio routing, source arbitration і Web API.

Інтерфейс не захардкоджений. Entry point визначає активний multicast IPv4 interface через системну routing table для SSDP `239.255.255.250`; за потреби його можна явно задати через:

```text
PROAUDIO_DLNA_INTERFACE=<interface>
```

Порт renderer:

```text
PROAUDIO_DLNA_PORT=49494
```

Допустимий діапазон gmediarender: `49152..65535`. Loopback не використовується, оскільки libupnp відхиляє loopback interface для `UpnpInit2`. Docker не містить припущень про `eth0`, `wlan0`, `enp*` або адресу локальної мережі.

## Sources

```text
sources/proaudio-player-native -> bodzey/proaudio-player-native / dev
sources/proaudio-player-webui  -> bodzey/proaudio-player-webui / dev
```

Оновлення:

```bash
git submodule sync --recursive
git submodule update --init --recursive
./docker/proaudio-player-dockerctl sync-sources
```

Gitlink-и є bootstrap snapshot. `sync-sources` оновлює working checkout до branch policy з `.gitmodules`.

## Запуск без фізичного аудіо

```bash
./docker/proaudio-player-dockerctl init
./docker/proaudio-player-dockerctl up-test
./docker/proaudio-player-dockerctl status
```

Web UI/API:

```text
http://HOST:5371/
http://HOST:5371/api/v1/health
```

Порт змінюється через `PROAUDIO_HTTP_PORT`.

## Generic ALSA passthrough

Для Linux host із фізичним audio device:

```bash
./docker/proaudio-player-dockerctl up-hardware
```

За потреби:

```bash
./docker/proaudio-player-dockerctl select-audio
```

Вибір sink зберігається у `docker-data/data/audio-output.env`.

## Дані

```text
docker-data/config/  runtime config, token, audio.env.override
docker-data/data/    persistent native/MPD state and machine-id
docker-data/music/   local music library
```

`/run/proaudio-player` тепер є звичайним ephemeral runtime directory всередині єдиного container; shared Docker volume для координації двох контейнерів більше не потрібен.

## Перевірка

```bash
python3 -m venv .venv
. .venv/bin/activate
pip install -r requirements-test.txt
pytest -q

./docker/proaudio-player-dockerctl up-test
curl -fsS http://127.0.0.1:5371/api/v1/health
./docker/proaudio-player-dockerctl status
```

Деталі runtime contract: [docs/DOCKER.md](docs/DOCKER.md).
