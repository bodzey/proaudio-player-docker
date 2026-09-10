# ProAudio Player Docker

Docker/Compose runtime для запуску **`proaudio-player-native/dev`** та **`proaudio-player-webui/dev`** на Linux amd64.

Цей репозиторій містить тільки Docker-адаптер. Код плеєра й Web UI не дублюється і не змінюється тут: обидва проєкти підключені окремими Git submodule та відстежують гілку `dev`.

## Джерела

```text
sources/proaudio-player-native   -> bodzey/proaudio-player-native (dev)
sources/proaudio-player-webui    -> bodzey/proaudio-player-webui  (dev)
```

Native daemon збирається Rust toolchain 1.88 у multi-stage Docker build. Web UI не компілюється в binary: його статичні файли встановлюються в `/usr/share/proaudio-player/webui`, звідки їх віддає native API.

## Клонування

```bash
git clone --branch dev --recurse-submodules git@github.com:bodzey/proaudio_player_docker.git
cd proaudio_player_docker
chmod +x docker/proaudio-player-dockerctl
```

Для вже існуючого clone:

```bash
git checkout dev
git pull
git submodule sync --recursive
git submodule update --init
```

Оновити обидва джерела до поточного стану їхніх `dev`-гілок:

```bash
./docker/proaudio-player-dockerctl sync-dev
```

Перевірити зафіксовані ревізії:

```bash
./docker/proaudio-player-dockerctl revisions
```

## Перший запуск без фізичного аудіопристрою

```bash
./docker/proaudio-player-dockerctl init
./docker/proaudio-player-dockerctl up-test
./docker/proaudio-player-dockerctl status
```

`up-test` створює внутрішній null sink, тому контейнер можна повністю перевірити на amd64 сервері без `/dev/snd`.

Web UI та API:

```text
http://IP_СЕРВЕРА:8080/
http://IP_СЕРВЕРА:8080/api/v1/health
```

## Запуск із фізичним ALSA-пристроєм

На хості має існувати `/dev/snd`.

```bash
./docker/proaudio-player-dockerctl up-hardware
```

Контейнер отримує тільки `/dev/snd` і read-only `/run/udev`. PipeWire автоматично вибере фізичний sink; USB-вихід має пріоритет відповідно до `audio-buses.sh` native-проєкту.

За потреби вибрати вихід вручну:

```bash
./docker/proaudio-player-dockerctl select-audio
./docker/proaudio-player-dockerctl up-hardware
```

Вибір зберігається в `docker-data/data/audio-output.env`. Це той самий runtime-контракт, який використовує native API. Зміна виходу через Web UI також застосовується контейнером без systemd завдяки `audio-output-watch`.

## Дані

```text
docker-data/config/   config.yaml, audio.env, MPD/AirPlay/Spotify configs, alerts-token
docker-data/data/     native state, settings, MPD state, machine-id, selected audio output
docker-data/music/    локальна музична бібліотека
```

`machine-id` зберігається в persistent data, тому UPnP/4STREAM identity не змінюється після rebuild контейнера.

## Корисні команди

```bash
./docker/proaudio-player-dockerctl sync-dev
./docker/proaudio-player-dockerctl revisions
./docker/proaudio-player-dockerctl status
./docker/proaudio-player-dockerctl logs
./docker/proaudio-player-dockerctl sinks
./docker/proaudio-player-dockerctl state
./docker/proaudio-player-dockerctl test-cycle 5
./docker/proaudio-player-dockerctl test-silence
./docker/proaudio-player-dockerctl mpd-update
./docker/proaudio-player-dockerctl shell
./docker/proaudio-player-dockerctl down
```

## Мережа

Compose використовує `network_mode: host`. Це навмисно: Spotify Connect, AirPlay/Avahi, DLNA/UPnP, SSDP та LinkPlay/4STREAM discovery мають працювати без окремого переліку проброшених multicast/UDP портів.

## Тести Docker-адаптера

```bash
python3 -m venv .venv
. .venv/bin/activate
pip install -r requirements-test.txt
git submodule update --init
pytest -q
```

Докладніша схема runtime: [docs/DOCKER.md](docs/DOCKER.md).
