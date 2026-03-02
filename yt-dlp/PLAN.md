# План улучшения скриптов yt-dlp

## Текущее состояние (v11, актуализировано 2026-03-03)

Все оригинальные скрипты (v7, v10, youtube-dl.sh, youtube-dl_sub.sh) полностью переписаны в v11.
Секции A-G реализованы. Осталась только секция H (Web GUI).

| Скрипт | Платформа | Назначение | Статус |
|--------|-----------|------------|--------|
| Downloading_from_YouTube_v11.sh | Linux/macOS/Git Bash | Универсальный CLI: одиночная загрузка, batch, субтитры, перевод | ГОТОВ |
| Downloading_from_YouTube_v11.cmd | Windows | Интерактивный CLI с меню | ГОТОВ |
| Downloading_from_YouTube_v11.ps1 | Windows | GUI (WinForms): очередь URL, прогресс, перевод, cookies | ГОТОВ |
| config.ini | Все | Общий конфиг: прокси, cookies, качество, перевод | ГОТОВ |
| build_exe.ps1 | Windows | Сборка PS1 -> EXE через ps2exe | ГОТОВ |
| VideoDownloader.exe | Windows | Скомпилированный GUI | ГОТОВ |

**Бинарные зависимости (в папке):** yt-dlp.exe, deno.exe, vot-cli-live.exe

---

## A-G. Реализованные секции

> Все задачи из секций A-G полностью выполнены при переходе на v11.

### A. Критические баги — ВЫПОЛНЕНО
Все баги из оригинальных скриптов (A1-A4) устранены полной перезаписью на v11:
- Валидация URL (CMD), правильные пробелы в аргументах, корректные format ID
- Прокси из config.ini вместо хардкода, UTF-8 кодировка
- Флаги `-c -i -w` во всех скриптах

### B. Стабильность — ВЫПОЛНЕНО
- `set -uo pipefail` в bash-скрипте
- `chcp 65001` в CMD
- Проверка зависимостей (yt-dlp, ffmpeg, vot-cli-live) с инструкциями установки
- `--download-archive` для пропуска уже скачанных видео
- Формат `bestaudio+bestvideo[height<=NNN][vcodec^=avc1]` по умолчанию (avc1_best)
- Корректная обработка путей с пробелами и кириллицей

### C. Улучшение вывода — ВЫПОЛНЕНО
- Цветной вывод в bash (ANSI-коды: RED, GREEN, YELLOW, CYAN)
- RichTextBox в GUI с цветными статусами
- Итоговая сводка (OK / пропущено / ошибки / время)
- Получение и отображение названия видео в CMD перед загрузкой
- Прогресс-бар в GUI (парсинг `[download] XX.X%`)
- Версия yt-dlp в заголовке GUI

### D. Поддержка cookies — ВЫПОЛНЕНО
- config.ini: секция `[cookies]` (method: none/file/browser, browser: chrome/firefox/edge)
- CLI (.sh): `--cookies browser`, `--cookies file`, `--cookie-browser NAME`
- CMD: интерактивное меню (0-4) с выбором метода cookies
- GUI: радиокнопки "Без cookies" / "Из браузера" / "Из файла" + ComboBox браузера

### E. Кроссплатформенность — ВЫПОЛНЕНО (без parse-vtt.py)
- config.ini создан с секциями: proxy, cookies, output, download, subtitles, batch, translation
- Bash-скрипт читает config.ini, поддерживает все режимы (URL, --batch, --subs, --translate)
- CMD читает config.ini косвенно (через встроенные настройки)
- GUI читает config.ini как значения по умолчанию
- **Не реализовано:** parse-vtt.py (VTT-парсер) и channels.txt (batch-загрузка только через .sh)

### G. Переведённая аудиодорожка — ВЫПОЛНЕНО
- vot-cli-live.exe включён в папку (портативный, без зависимости от Node.js/npm)
- Три режима: dual_track (2 дорожки), replace (только перевод), mix (оригинал приглушён)
- Проверка зависимостей с fallback: сначала ищет рядом со скриптом, потом в PATH
- config.ini: секция `[translation]` (enabled, target_lang, voice_style, mode, volumes)
- CLI (.sh): `--translate ru`, `--voice tts`, `--mix`, `--replace`
- CMD: меню AI-перевода (0-4)
- GUI: чекбокс + ComboBox-ы (язык, режим, голос)

---

## H. Современный Web GUI (HTML/CSS/JS + Node.js Express) — НЕ РЕАЛИЗОВАНО

### H1. Концепция

Заменить PowerShell WinForms GUI (`download-gui.ps1`) на современный веб-интерфейс.
Открывается в браузере, работает на любой ОС где есть Node.js.

**Стек:**
- **Backend:** Node.js + Express (HTTP-сервер + REST API)
- **Realtime:** WebSocket (npm `ws`) — стриминг вывода yt-dlp в браузер
- **Frontend:** Ванильный HTML/CSS/JS (без фреймворков)
- **Процессы:** `child_process.spawn` — запуск yt-dlp

**Запуск:** `node gui/server.js` -> автооткрытие `http://localhost:3100`

### H2. Структура файлов

```
yt-dlp/gui/
├── package.json          # express, ws, open
├── server.js             # Express + WebSocket + child_process
├── config-parser.js      # Чтение/запись config.ini (общий модуль)
└── public/
    ├── index.html        # Единственная HTML-страница
    ├── style.css         # Тёмная тема, анимации
    └── app.js            # WebSocket-клиент, UI-логика, state
```

Скрипты запуска:
```
yt-dlp/start-gui.cmd      # @echo off & node gui/server.js
yt-dlp/start-gui.sh        # #!/bin/bash & node gui/server.js
```

### H3. API endpoints (server.js)

| Метод | Путь | Описание |
|-------|------|----------|
| GET | `/` | Статические файлы (`public/`) |
| GET | `/api/config` | Читает `config.ini`, возвращает JSON |
| POST | `/api/config` | Сохраняет изменения в `config.ini` |
| GET | `/api/versions` | `{ ytdlp, ffmpeg, node, votcli }` — версии всех утилит |
| POST | `/api/update-ytdlp` | Запускает `yt-dlp -U`, стримит результат через WebSocket |
| POST | `/api/download` | Запускает yt-dlp, стримит вывод через WebSocket |
| POST | `/api/stop` | Убивает текущий процесс yt-dlp |
| GET | `/api/state` | Читает `gui_state.json` (сохранённое состояние GUI) |
| POST | `/api/state` | Сохраняет `gui_state.json` |
| GET | `/api/channels` | Читает `channels.txt` |
| POST | `/api/channels` | Сохраняет `channels.txt` |
| WebSocket | `/ws` | Стриминг stdout/stderr yt-dlp -> клиенту |

### H4. Логика загрузки (очередь)

**Очередь URL:**
1. Клиент отправляет `POST /api/download` с JSON:
   ```json
   {
     "urls": [
       { "url": "https://youtube.com/watch?v=abc", "quality": "720" },
       { "url": "https://rutube.ru/video/xyz", "quality": "1080" }
     ],
     "cookies": { "method": "browser", "browser": "chrome" },
     "proxy": "",
     "translate": { "enabled": false }
   }
   ```
2. Сервер обрабатывает URLs **последовательно**
3. Для каждого URL: `spawn('yt-dlp', args)` -> стримит stdout/stderr через WebSocket
4. WebSocket-сообщения:
   ```json
   { "type": "progress", "percent": 67.3, "url": "...", "index": 0, "total": 3 }
   { "type": "output", "data": "[download] 67.3% of 150MiB at 5.2MiB/s" }
   { "type": "status", "status": "done", "index": 0 }
   { "type": "status", "status": "error", "index": 1, "error": "..." }
   { "type": "summary", "ok": 2, "fail": 1, "time": "4m 23s" }
   ```
5. Клиент обновляет прогресс-бар, статус каждого URL в очереди, лог

**Управление очередью в GUI:**
- Поле ввода URL + кнопка `[+]` (или Enter)
- Вставка нескольких URL через перенос строки (textarea popup)
- Кнопка `[x]` для удаления из очереди
- Статус каждого URL: pending -> downloading -> done / error
- Drag & drop для изменения порядка (опционально)

### H5. Поддержка других платформ

yt-dlp уже поддерживает 1000+ сайтов. Никакой специальной логики не нужно — только визуальная часть.

**В GUI:**
- При добавлении URL — автоопределение платформы по домену:
  ```javascript
  const platforms = {
    'youtube.com': { name: 'YouTube', color: '#ff0000' },
    'youtu.be': { name: 'YouTube', color: '#ff0000' },
    'rutube.ru': { name: 'RuTube', color: '#1a9fff' },
    'vk.com': { name: 'VK Video', color: '#0077ff' },
    'dailymotion.com': { name: 'Dailymotion', color: '#00d2f3' },
    'twitch.tv': { name: 'Twitch', color: '#9146ff' },
    'vimeo.com': { name: 'Vimeo', color: '#1ab7ea' },
  }
  ```
- В очереди — бейдж с названием платформы рядом с URL

### H6. Версии и обновления

**Отображение в шапке GUI:**
```
YouTube Downloader v1.0          yt-dlp 2025.01.15 | ffmpeg 7.1 | Node 22.1
```

**Кнопка "Обновить yt-dlp":**
- `POST /api/update-ytdlp` -> запускает `yt-dlp -U`
- Результат стримится через WebSocket в лог

### H7. Сохранение состояния

Файл `gui/gui_state.json` — автосохранение при каждом изменении настроек.

```json
{
  "lastUrl": "https://youtube.com/...",
  "quality": "720",
  "folder": "C:/Users/.../videos",
  "proxy": "",
  "cookies": { "method": "none", "browser": "chrome" },
  "translate": { "enabled": false, "lang": "ru", "mode": "dual_track", "voice": "live" },
  "playlistStart": "",
  "playlistEnd": "",
  "ytdlpPath": "yt-dlp",
  "queue": []
}
```

### H8. Дизайн (тёмная тема)

**Цветовая палитра:**
```css
:root {
  --bg-primary: #0d1117;        /* Основной фон */
  --bg-secondary: #161b22;      /* Карточки, панели */
  --bg-tertiary: #21262d;       /* Поля ввода, ховеры */
  --border: #30363d;            /* Бордеры */
  --text-primary: #e6edf3;      /* Основной текст */
  --text-secondary: #8b949e;    /* Вспомогательный текст */
  --accent-blue: #58a6ff;       /* Ссылки, фокус */
  --accent-green: #238636;      /* Успех, кнопка "Начать" */
  --accent-red: #da3633;        /* Ошибки, кнопка "Стоп" */
  --accent-yellow: #d29922;     /* Предупреждения */
  --accent-purple: #8957e5;     /* AI-перевод */
}
```

**Мокап интерфейса:**
```
+-------------------------------------------------------------+
|  YouTube Downloader                    v1.0 | yt-dlp 2025   |
|                                        [Обновить yt-dlp]     |
+-------------------------------------------------------------+
|                                                               |
|  +- Очередь загрузок ------------------------------------+   |
|  |  [URL input ................................] [+]      |   |
|  |                                                        |   |
|  |  1. [YouTube] https://youtu.be/abc    720p   [x]      |   |
|  |  2. [RuTube]  https://rutube.ru/...   1080p  [x]      |   |
|  |  3. [VK]      https://vk.com/...      720p   [x]      |   |
|  +--------------------------------------------------------+   |
|                                                               |
|  +- Настройки ----------+  +- Cookies ------------------+    |
|  | Качество: [720p v]   |  | (*) Без  ( ) Браузер ( )Ф  |    |
|  | Папка: [___] [...]   |  | Браузер: [Chrome v]        |    |
|  | Прокси: [________]   |  +-----------------------------+    |
|  | Плейлист: с[__]по[_] |                                     |
|  +-----------------------+  +- AI-перевод ---------------+    |
|                             | [ ] Включить               |    |
|                             | Язык:[RU v] Режим:[2 дор v]|    |
|                             | Голос: [live v]             |    |
|                             +-----------------------------+   |
|                                                               |
|  [> Начать загрузку]  [# Остановить]  [Очистить]             |
|                                                               |
|  ==================== 67%  video.mp4                          |
|                                                               |
|  +- Лог -------------------------------------------------+   |
|  | [download] Destination: video.mp4                      |   |
|  | [download] 67.3% of 150MiB at 5.2MiB/s                |   |
|  +--------------------------------------------------------+   |
+---------------------------------------------------------------+
```

### H9. Зависимости (package.json)

```json
{
  "name": "yt-dlp-gui",
  "version": "1.0.0",
  "description": "Modern web GUI for yt-dlp",
  "main": "server.js",
  "scripts": { "start": "node server.js" },
  "dependencies": {
    "express": "^4.21",
    "ws": "^8.18",
    "open": "^10.1"
  }
}
```

### H10. Порядок реализации GUI

1. Создать `gui/package.json`, установить зависимости
2. Реализовать `gui/config-parser.js` (чтение/запись config.ini)
3. Реализовать `gui/server.js` (API + WebSocket + spawn yt-dlp)
4. Создать `gui/public/index.html` (HTML-структура)
5. Создать `gui/public/style.css` (тёмная тема)
6. Создать `gui/public/app.js` (WebSocket, очередь, state)
7. Добавить определение платформ по домену
8. Добавить версии + обновление в шапку
9. Реализовать сохранение/загрузку состояния
10. Создать `start-gui.cmd` / `start-gui.sh`
11. Тестирование: YouTube URL, очередь из 3 URL, cookies, прокси

---

## Порядок оставшихся задач

| # | Задача | Секция | Статус |
|---|--------|--------|--------|
| 1 | Создать channels.txt (пример для batch-загрузки) | E3 | НЕ СДЕЛАНО |
| 2 | Написать parse-vtt.py (VTT -> текст) | E5 | НЕ СДЕЛАНО |
| 3 | Современный Web GUI | H | НЕ СДЕЛАНО |
