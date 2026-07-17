# Findings archive — video

Ledger закрытых находок (audit trail, не удаляется). Новые записи сверху.

## 2026-07-17 · Видеобитрейт ограничивается общим bitrate контейнера [P2]
**Context:** `.ps1:483-493`, `.cmd:459-476`; контракт `ffmpeg/config.ini:40`
**What:** Парсился `Duration ... bitrate` (video+audio+overhead), хотя настройка обещает не повышать исходный видеобитрейт.
**Status:** done
**Resolved:** 2026-07-17 — PS1/CMD приведены к SH (F25): потолок берётся из `Stream #...: Video: ..., N kb/s`, fallback на контейнер с WARN. Тесты: реальная `:kbps_from_line` (CMD), anti-regression на регекс (PS1).

## 2026-07-17 · GPU-путь CMD не покрыт поведенческими тестами [P2]
**Context:** `tests/ffmpeg/test_10_cmd.sh`, `test_11_cmd_smoke.sh`
**What:** Ни один CMD-тест не выставлял `hw_accel`, ветка GPU не исполнялась; дисбаланс кавычек в `:resolve_hw` был невидим при 20/20 и 50/50.
**Status:** done
**Resolved:** 2026-07-17 — поведенческий тест вызывает реальную `:resolve_hw` с mock-ffmpeg (список энкодеров): точный энкодер→hardware, libsvtav1 без av1_nvenc→software, кодек без GPU-варианта→software.

## 2026-07-17 · test_15_findings слишком медленный (~10+ мин) [P3]
**Context:** `tests/ffmpeg/test_15_findings.sh`
**What:** ~15 тяжёлых `source "$SCRIPT"` с реальным mock-кодированием; полный набор рвал 600с-таймаут.
**Status:** done
**Resolved:** 2026-07-17 — F16 и F29 гоняли идентичный split×4 → объединены в один прогон; в F17 убран лишний rebuild manifest. −2 тяжёлых прогона, 154/154 зелёные.

## 2026-07-17 · Guardrail числа тест-файлов был фиктивным (substring) [P3]
**Context:** `tests/common/test_guardrails.sh`
**What:** Проверка «числа файлов в README = runner» искала подстроку («6 файлов» находится в «16 файлов») — не могла упасть.
**Status:** done
**Resolved:** 2026-07-17 — числа извлекаются и сравниваются численно `assert_eq`, подтверждено провалом на устаревшем README (сделано в том же заходе, что и обнаружение).

## 2026-07-17 · Тесты могли уходить в реальную сеть через vot-cli-live [P2]
**Context:** `yt-dlp/Downloading_from_YouTube_v15.sh:132-147`
**What:** У `VOT_BIN` не было env-override; `check_translate_deps` перезатирал переменную бинарём рядом со скриптом → тест перевода запускал настоящий `vot-cli-live` и ~22с ходил в сеть.
**Status:** done
**Resolved:** 2026-07-17 — override для `VOT_BIN` сделан ранее; добавлен framework-guard: `framework.sh` кладёт в начало PATH poison-заглушку `vot-cli-live` (exit 97 при реальном вызове в обход мока). Регрессия теперь падает громко.

## 2026-07-17 · Split pipeline мог ложно считаться готовым [P2]
**Context:** `ffmpeg/FFmpeg_Converter_script.sh/.ps1/.cmd`
**What:** Один `part.1` без completion marker трактовался как «весь input готов».
**Status:** done
**Resolved:** 2026-07-17 — проверено: транзакционный manifest со `state=complete` + перечислением всех частей + сверкой размера источника реализован во ВСЕХ трёх платформах (SH/PS1/CMD, F16/F17). Тест F17 в test_15 подтверждает.

## 2026-07-17 · Заявленный AI-перевод мог завершиться «успехом» без результата [P2]
**Context:** `.ps1:1235-1238`, `.cmd:451,475,487,507`
**What:** PS1 считал download успехом до translation; CMD после ошибки уходил в skip_translate без смены итога.
**Status:** done
**Resolved:** 2026-07-17 — SH закрыт ранее (F14). Теперь PS1 GUI: флаг `$translateOk`, при провале `failCount++` + красное сообщение. CMD: `translate_ok` только при реальном успехе, иначе итог/цвет меняются и `exit /b 1`. Source-scan тесты для обеих платформ.

## 2026-07-17 · macOS-совместимость SH не проверялась в CI [P2]
**Context:** `README.md:59`; `.github/workflows/ci.yml`
**What:** Портируемость SH под macOS/Bash 3.2 держалась только на ревью.
**Status:** done
**Resolved:** 2026-07-17 — несовместимости устранены ранее (`${ext,,}`→tr, `sort -z`→sort_null, `stat -f%z` fallback). Добавлен CI lane `macos-tests` (системный /bin/bash 3.2 + BSD-userland, SH+common; CMD/PS1 скипаются без STRICT_SKIP).

## 2026-07-17 · Release manifest не соответствовал HEAD и артефактам [P2]
**Context:** `release-manifest.json`; `tools/check_release.ps1`; `.github/workflows/ci.yml`
**What:** Manifest указывал устаревший commit и SHA артефактов, не совпадающие с EXE (sidecar при этом совпадали). CI проверял только EXE↔sidecar.
**Status:** done
**Resolved:** 2026-07-17 — манифест синхронизирован с закоммиченными EXE (source_commit=b711667, dirty=false, SHA=факт). CI-gate сверяет треугольник manifest↔EXE↔sidecar. check_release.ps1 фиксирует dirty ДО сборки и падает на грязном входе.

## 2026-07-17 · Первый провал build chain мог маскироваться вторым успехом [P2]
**Context:** `.github/workflows/ci.yml`, `tools/check_release.ps1`
**What:** Последовательные `powershell -File ...` не проверяли `$LASTEXITCODE` после каждой сборки; провал первой маскировался успехом второй.
**Status:** done
**Resolved:** 2026-07-17 — после каждой сборки EXE проверяется `$LASTEXITCODE` (throw при провале) и в check_release.ps1, и в CI smoke-шаге.

## 2026-07-17 · CI не покрывал заявленную защиту PII/private infrastructure [P2]
**Context:** `README.md:195-208`, `.github/workflows/ci.yml`, `.githooks/pre-commit`
**What:** README обещал двухуровневую защиту PII, но CI запускал только gitleaks (секреты); PII/private IP покрывал лишь опциональный локальный denylist.
**Status:** done
**Resolved:** 2026-07-17 — добавлен `tools/privacy-scan.sh` (POSIX sh, single source): скан всего дерева на приватные IPv4 (RFC1918) и e-mail, исключая *.example-плейсхолдеры. Подключён в CI. README приведён к реальности.

## 2026-07-17 · Активные status/test документы устарели [P2]
**Context:** `tests/TESTING.md`, local `AGENTS.md`
**What:** Per-file counts в TESTING отставали от набора; AGENTS ошибочно называл mock-изолированный yt-dlp integration «сетевым».
**Status:** done
**Resolved:** 2026-07-17 — из TESTING убраны волатильные per-file числа (источник — раннер), добавлены недостающие файлы (yt-dlp 05-08, ffmpeg 08-16). AGENTS: убраны захардкоженные 917/332/265; исправлена пометка про test_04_integration.

## 2026-07-17 · Статистика split и skip не отражала реальную работу [P3]
**Context:** `ffmpeg/FFmpeg_Converter_script.sh/.ps1`; `yt-dlp/Downloading_from_YouTube_v15.sh`
**What:** FFmpeg добавлял полный input size за каждую часть; yt-dlp объявлял `COUNT_SKIP`, но нигде не увеличивал.
**Status:** done
**Resolved:** 2026-07-17 — ffmpeg-часть (вход один раз на source) уже была закрыта F29. yt-dlp: `COUNT_SKIP` инкрементится при archive-skip (пустой manifest при включённом архиве = видео уже скачано → «Пропущено», return 2). Тест в test_08.
