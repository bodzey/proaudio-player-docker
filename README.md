# ProAudio Player Docker

Docker/Compose integration layer for `bodzey/proaudio_player`.

Цей репозиторій призначений для розробки та інтеграційного тестування ProAudio Player на Linux amd64 або aarch64. Він не містить копію ядра: `proaudio_player` підключається як Git submodule у `sources/proaudio-player` і фіксується на конкретному commit з гілки `main`.

## Модель репозиторіїв

```text
proaudio_player                  platform-independent core
        │
        ├── proaudio_player_docker     Docker / dev + testing
        └── proaudio-player-firmware   Buildroot / Raspberry Pi 4
```

Поточний pinned core commit (`proaudio_player/main`):

```text
5e16db504c4760c739a48fd2a4b4d81cbfa09323
```

## Клонування

```bash
git clone --recurse-submodules git@github.com:bodzey/proaudio_player_docker.git
cd proaudio_player_docker
```

Відносний URL submodule автоматично використовує протокол основного clone: SSH для SSH clone або HTTPS для HTTPS clone.

Для вже клонованого репозиторію:

```bash
git submodule update --init --recursive
```

Перевірити версію ядра:

```bash
./docker/proaudio-player-dockerctl core-rev
```

## Локальні тести adapter + pinned core

```bash
python3 -m venv .venv
. .venv/bin/activate
pip install -r requirements-test.txt
git submodule update --init --recursive
pytest -q
```

`requirements-test.txt` встановлює pinned `sources/proaudio-player` як editable package разом із його runtime/test залежностями. `pytest -q` запускає тести Docker adapter та тести саме тієї ревізії core, яка зафіксована submodule.

## Ініціалізація

```bash
chmod +x docker/proaudio-player-dockerctl
./docker/proaudio-player-dockerctl init
nano docker-data/config/alerts-token
```

## Тест без фізичного аудіовиходу

```bash
./docker/proaudio-player-dockerctl up-test
./docker/proaudio-player-dockerctl status
./docker/proaudio-player-dockerctl test-cycle 5
```

## Тест із фізичним ALSA-пристроєм

```bash
./docker/proaudio-player-dockerctl select-audio
./docker/proaudio-player-dockerctl up-hardware
./docker/proaudio-player-dockerctl sinks
```

Контейнер отримує `/dev/snd` і `/run/udev:ro`. Майстер discovery запускає тимчасовий PipeWire/WirePlumber stack і зберігає вибір у `docker-data/config/audio-device.env`.

## Дані

Persistent development data не входять до Git:

```text
docker-data/config/    runtime config + alerts token + audio selection
docker-data/data/      state + alert media + MPD state
docker-data/music/     local music library
```

Під час першого запуску стандартні MP3-сповіщення копіюються з pinned core. Власні файли в `docker-data/data/media/` при rebuild не перезаписуються.

## Web UI

Після запуску web UI доступний у LAN:

```text
http://IP_СЕРВЕРА:8080
```

Compose використовує `network_mode: host`, що також потрібне для mDNS/Spotify Connect/DLNA discovery.

## Оновлення ядра

Робоча гілка в усіх трьох репозиторіях — `main`. Docker не копіює core, а pin-ить конкретний commit із `proaudio_player/main`.

Для оновлення до поточного `main` ядра:

```bash
cd sources/proaudio-player
git fetch origin main
git checkout origin/main
cd ../..
git add sources/proaudio-player
git commit -m "chore: update player core main"
```

Після цього:

```bash
./docker/proaudio-player-dockerctl up-test
```

Докладніше: [docs/DOCKER.md](docs/DOCKER.md).
