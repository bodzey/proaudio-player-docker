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

Окремого DLNA sidecar-контейнера немає.

## Hardware neutrality

Docker runtime не містить Raspberry Pi, SoC, board name, конкретної звукової карти або фіксованої назви LAN-інтерфейсу.

Також Compose не задає `platform: linux/amd64`. Image збирається для архітектури Docker host/build platform; підтримка конкретної CPU-архітектури визначається доступністю upstream base images і залежностей, а не кодом цього репозиторію.

Стандартний `compose.yaml` не вимагає фізичного audio device. Без `/dev/snd` native audio graph використовує PARKING sink.

Опціональний `compose.hardware.yaml` є лише generic Linux ALSA passthrough:

```text
/dev/snd
/run/udev:ro
```

Він не знає модель DAC, USB VID/PID, Raspberry Pi або назву ALSA card.

## Network discovery

Основний container використовує `network_mode: host`, оскільки AirPlay, Avahi, Spotify Connect та DLNA використовують LAN multicast/discovery.

Для DLNA Docker entrypoint автоматично вибирає IPv4 interface з default route. Якщо потрібно, interface можна задати:

```bash
PROAUDIO_LAN_INTERFACE=enp3s0
```

Назва `eth0` ніде не є архітектурним припущенням.

У Docker режимі `gmediarender` є єдиним LAN-facing DLNA MediaRenderer. Native public UPnP proxy вимикається через `PROAUDIO_UPNP_PUBLIC=false`, а native control plane працює з gmediarender через автоматично сформований `PROAUDIO_DLNA_ENDPOINT`.

Порт DLNA:

```text
PROAUDIO_DLNA_PORT=49494
```

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
