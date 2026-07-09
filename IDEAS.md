# Ideas — video

Предложения фич и улучшений от project-analysis. Статусы: proposed | accepted | rejected | done.

## 2026-07-08 · Добавить CI secret scan
**Контекст:** public repo сейчас полагается на локальный pre-commit.
**Что:** CI-скан снизит риск обхода через неактивный hook, web-commit, force-add или другого автора.
**Предложение:** добавить GitHub Actions job с `gitleaks` или `trufflehog`, плюс scan history на PR/ручной запуск.
**Статус:** proposed

## 2026-07-08 · Добавить безопасный bootstrap для public repo
**Контекст:** `.githooks/pre-commit` требует ручной настройки.
**Что:** новый clone легко забывает `git config core.hooksPath .githooks`.
**Предложение:** добавить `scripts/bootstrap-public-repo.*` или README-блок: активировать hooks, проверить `.sanitize-patterns`, запустить secret scan.
**Статус:** proposed

## 2026-07-08 · Добавить `.sanitize-patterns.example` без приватных значений
**Контекст:** локальный `.sanitize-patterns` gitignored.
**Что:** новым клонам непонятно, какие типы локальных значений туда класть.
**Предложение:** tracked `.sanitize-patterns.example` с fake placeholders: proxy host, proxy user, internal domain, private email, local path patterns.
**Статус:** proposed

## 2026-07-08 · Единый parity harness для yt-dlp command builder
**Контекст:** SH/PS1/CMD yt-dlp имеют разные UX-модели, а тесты частично проверяют source snippets.
**Что:** сейчас сложно увидеть, какие различия sanctioned, а какие drift.
**Предложение:** добавить neutral matrix tests, где один набор inputs (`quality`, `format_preset`, `subs`, `sponsorblock`, `trim`) сравнивает итоговые yt-dlp args по платформам или явно маркирует intentional differences.
**Статус:** proposed

## 2026-07-08 · Машиночитаемый manifest config keys -> platforms
**Контекст:** `test_config_keys.sh` уже задаёт важный контракт, но он спрятан в grep-логике.
**Что:** intentional gaps вроде yt-dlp CMD видны только при чтении теста.
**Предложение:** завести `tests/config-key-contract.yaml` с полями `key`, `section`, `ffmpeg: [sh,cmd,ps1]`, `yt-dlp: [sh,ps1]`, `exceptions`.
**Статус:** proposed

## 2026-07-08 · Adversarial path/filename matrix for Windows shells
**Контекст:** текущие тесты покрывают encoding и точечные quote assertions.
**Что:** нет полноценного end-to-end набора для сложных имён и путей.
**Предложение:** добавить матрицу: пробелы, Unicode, `!`, `%`, `^`, `&`, `'`, `#`, trailing slash, UNC, `C:relative`.
**Статус:** proposed

## 2026-07-08 · Shared Windows argv builder for PS1 tools
**Контекст:** yt-dlp GUI и subprocess-вызовы вручную собирают command line.
**Что:** единый helper снизит риск расхождений и quote bugs.
**Предложение:** вынести Windows-quoting helper и использовать в yt-dlp GUI, vot-cli-live и любых `ProcessStartInfo.Arguments`.
**Статус:** proposed

## 2026-07-08 · Static guardrail tests for dangerous shell patterns
**Контекст:** аудит нашёл повторяющиеся риск-паттерны вокруг command construction, delayed expansion и temp dirs.
**Что:** эти паттерны удобно ловить до ревью.
**Предложение:** добавить read-only тест, который фейлит на новых `Arguments = ... -join " "`, `powershell -Command "...'%path%'"`, `enabledelayedexpansion` вокруг file paths без guard и temp paths на `%RANDOM%`.
**Статус:** proposed

## 2026-07-08 · Release verification script
**Контекст:** release hygiene сейчас ручной.
**Что:** перед релизом нужно помнить тесты, сборку обоих EXE, `.sha256`, `git status` и ps2exe provenance.
**Предложение:** добавить `tools/check_release.ps1`: прогон тестов, сборка EXE, сверка hashes, проверка clean tree, вывод версии и SHA ps2exe.
**Статус:** proposed

## 2026-07-08 · CI matrix с явными expected skips
**Контекст:** общий runner может зеленеть на skip платформенных suite’ов.
**Что:** Linux и Windows должны иметь разные ожидания по доступности CMD/PS1.
**Предложение:** разделить CI на Linux Bash lane и Windows parity lane; на Windows CMD/PS1 skips должны падать, на Linux они допустимы только в ограниченном профиле.
**Статус:** proposed

## 2026-07-08 · Provenance для EXE артефактов
**Контекст:** `.exe` и `.sha256` отслеживаются Git’ом.
**Что:** по одному hash-файлу трудно понять source commit, BuildVersion и ps2exe origin.
**Предложение:** добавить `release-manifest.json` с source commit, BuildVersion, ps2exe commit/SHA и artifact SHA, либо перенести EXE в GitHub Releases.
**Статус:** proposed

## 2026-07-08 · Уменьшить source-scan blind spots
**Контекст:** часть тестов проверяет inline-копии или строки в исходниках.
**Что:** такие тесты могут зеленеть при drift production behavior.
**Предложение:** больше проверять реальные dry-run/runtime paths, особенно для CMD/PS1.
**Статус:** proposed
