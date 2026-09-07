# ProAudio Player Docker

Docker/Compose integration layer for `bodzey/proaudio_player`.

Цей репозиторій призначений для розробки та інтеграційного тестування ProAudio Player на Linux amd64 сервері. Він не містить копію ядра: `proaudio_player` підключається як Git submodule у `sources/proaudio-player` і фіксується на конкретному commit.

## Модель репозиторіїв

```text
proaudio_player                  platform-independent core
        │
        ├── proaudio_player_docker     Docker / amd64 dev + testing
        └── proaudio-player-firmware   Buildroot / Raspberry Pi 4
```

Поточний pinned core commit:

```text
669df8465929fb1b582aa6cb3ffa3a8fd8128e72
```

## Клонування

```bash
git clone --recurse-submodules git@github.com:bodzey/proaudio_player_docker.git
cd proaudio_player_docker
```

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

## Web UI

Після запуску web UI доступний у LAN:

```text
http://IP_СЕРВЕРА:8080
```

Compose використовує `network_mode: host`, що також потрібне для mDNS/Spotify Connect/DLNA discovery.

## Оновлення ядра

Core не копіюється в цей репозиторій. Для тестування іншого commit:

```bash
cd sources/proaudio-player
git fetch
git checkout <commit-or-tag>
cd ../..
git add sources/proaudio-player
git commit -m "chore: update player core"
```

Після цього:

```bash
./docker/proaudio-player-dockerctl up-test
```

Production/stable Docker revisions повинні pin-ити release tag або перевірений commit, а не автоматично слідувати за `main`.

Докладніше: [docs/DOCKER.md](docs/DOCKER.md).
