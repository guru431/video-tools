# Ideas — video

Предложения функционального развития. Реализованные и отклонённые удаляются.

## 2026-07-13 · Транзакционный output pipeline и безопасный resume
**Value:** исключает повреждение/потерю оригиналов и позволяет продолжать прерванные batch/split/merge.
**MVP:** писать каждый результат в adjacent `.partial`, проверять ffprobe, атомарно переименовывать; хранить manifest input → outputs → hashes → completion state.
**Status:** proposed

## 2026-07-13 · `--check-config` и `--plan-json` для всех платформ
**Value:** пользователь до запуска увидит ошибки значений, точные input/output, collisions, resolved codecs, split boundaries, команды, объём и свободное место.
**MVP:** read-only preflight с единым JSON schema; CLI печатают JSON/таблицу, GUI показывает preview и блокирует Run при P1/P2 validation errors.
**Status:** proposed

## 2026-07-13 · Точный output handshake с yt-dlp
**Value:** убирает поиск файлов по mtime, делает перевод надёжным и открывает корректную обработку нескольких outputs/плейлистов.
**MVP:** получать официальный `--print after_move:filepath` в per-process JSON, привязывать каждый путь к item и передавать дальше в post-processing state machine.
**Status:** proposed

## 2026-07-13 · Адаптивная format policy вместо хрупких numeric itag
**Value:** пресеты переживут изменения extractor-specific format IDs и смогут объяснить пользователю выбор codec/container/resolution/FPS/HDR.
**MVP:** выражать предпочтения через документированные yt-dlp selectors и [`--format-sort`](https://github.com/yt-dlp/yt-dlp/blob/master/README.md#sorting-formats), оставить numeric itag только как явно legacy preset; добавить canary на актуальный `-F`.
**Status:** proposed

## 2026-07-13 · Отменяемый AI-translation worker с cache
**Value:** GUI не зависает, Stop действительно прекращает vot/ffmpeg, повторный перевод того же video-id/lang/voice не делает сетевую работу заново.
**MVP:** async worker с timeout/cancellation, per-stage status, temp cleanup и cache key; оригинал сохранять, atomic replace разрешать только после ffprobe validation.
**Status:** proposed

## 2026-07-13 · Resumable GUI queue и parity с channels batch
**Value:** пользователь сможет импортировать `channels.txt`, видеть category/handle/mode, приостанавливать очередь и продолжать после перезапуска.
**MVP:** JSON queue manifest со статусами queued/downloaded/postprocessed/translated/partial/failed; импорт/preview channels в PS1 GUI. Интерактивный CMD можно оставить санкционированным исключением.
**Status:** proposed

## 2026-07-13 · Политика субтитров и мультиязычный workflow
**Value:** ручные captions не теряются, auto используются как fallback, можно получать несколько языков и bilingual sidecars.
**MVP:** режимы `manual-preferred|auto-fallback|both`, regex languages, `srt|ass|vtt`, embed/sidecar, выбор `movie.ru.srt`; использовать `--write-subs` вместе с контролируемым `--write-auto-subs`.
**Status:** proposed

## 2026-07-13 · Split preview: waveform, главы и редактируемые границы
**Value:** нарезку по тишине можно проверить до дорогого encode и вручную убрать плохие точки.
**MVP:** manifest границ + длительностей, простой waveform/таблица preview, ручное включение/сдвиг boundary; опционально импорт глав и yt-dlp [`--split-chapters`](https://github.com/yt-dlp/yt-dlp/blob/master/README.md#post-processing-options).
**Status:** proposed

## 2026-07-13 · Явный merge manifest и fallback несовместимых потоков
**Value:** порядок объединения перестаёт зависеть от имени/FS, а несовместимые файлы не дают загадочный concat failure.
**MVP:** drag-and-drop/natural-sort список, собственное имя output, ffprobe-проверка stream layout; быстрый stream-copy или opt-in transcode-to-common-profile fallback.
**Status:** proposed

## 2026-07-13 · Hardware capability report и автоматический per-file fallback
**Value:** пользователь заранее увидит реальные encoder/decoder/device capabilities, а один неподдерживаемый codec не уронит весь batch.
**MVP:** probe точных NVENC/QSV/AMF encoders и короткий device smoke; сохранить отчёт, выбирать CPU fallback отдельно для каждого файла и объяснять причину в summary.
**Status:** proposed

## 2026-07-13 · Управление скоростью и устойчивостью загрузки
**Value:** медленные/нестабильные сети и большие плейлисты можно настраивать без редактирования скрипта.
**MVP:** config/GUI для `--concurrent-fragments`, rate/throttled-rate, retries/retry-sleep, socket timeout и внешнего downloader; безопасные пресеты «бережно / обычно / быстро» на базе [официальных download options](https://github.com/yt-dlp/yt-dlp/blob/master/README.md#download-options).
**Status:** proposed

## 2026-07-13 · Secure proxy UX без plaintext password в config
**Value:** сохраняет portable setup, но уменьшает риск попадания credentials в repo, LLM context, logs и screenshots.
**MVP:** masked GUI field + ссылка на env/Windows Credential Manager, единый resolver credentials, диагностические сообщения в GUI/status без раскрытия значения.
**Status:** proposed

## 2026-07-13 · Machine-readable summary и история заданий
**Value:** cron/CI/GUI получают одинаковый честный результат по каждому файлу и stage вместо одного process exit code.
**MVP:** `--json-summary` с ok/skip/partial/fail/cancelled, exact paths, bytes, elapsed, warnings и exit codes; GUI умеет открыть прошлый job и повторить только failed items.
**Status:** proposed

## 2026-07-13 · Генерируемая capability/docs/release матрица
**Value:** test counts, platform exceptions, README и release provenance перестают расходиться вручную.
**MVP:** расширить `config-key-contract.yaml` до feature matrix; CI генерирует/проверяет таблицы, ссылки, v15 references, placeholders и HEAD↔manifest↔EXE↔sidecar.
**Status:** proposed
