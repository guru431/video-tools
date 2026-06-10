# Ideas — video
Предложения фич от project-analysis. Статусы: proposed | accepted | rejected | done.

## 2026-06-09 · Поддержка env-переменных в config.ini для credentials. Сейча...
**Боль:** INTENT явно требует: «публичный репозиторий — не допускать утечек, секреты только через env-переменные». Credentials в config.ini — прямой путь к утечке при каждом коммите.
**Предложение:** Добавить синтаксис подстановки ${ENV_VAR} в read_config всех трёх платформ: если значение содержит ${...}, подставлять из окружения. Пример: url = ${PROXY_URL} вместо url = https://user:pass@host:port. Реализовать в SH (read_config), CMD (:assign_var), PS1 (Read-Config) с паритетом.
**Что:** Поддержка env-переменных в config.ini для credentials. Сейчас proxy URL с логином/паролем хранится в config.ini в открытом виде — при коммите в публичный репозиторий это прямая утечка. Формат +value/-value не позволяет отделить секреты от конфигурации.
**Статус:** proposed

