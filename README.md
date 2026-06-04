# Solar Hermes Company Installer

Корпоративный установщик преднастроенного [Hermes Agent](https://github.com/NousResearch/hermes-agent) для работы через Solar LLM Platform:

- модель: `qwen3.6`
- API: `https://llm.solar-group.com/v1`
- авторизация: `Authorization: Bearer <LLM Platform API token>`
- локальное сжатие контекста: [Headroom](https://github.com/chopratejas/headroom)
- запуск после установки: `solar-hermes`

Реальные токены не хранятся в репозитории. Установщик спрашивает токен у пользователя в самом начале установки и сохраняет его локально в Hermes config (`~/.hermes/.env` на macOS/Linux или в реальном Hermes home на Windows, обычно `%LOCALAPPDATA%\hermes\.env`).

## One-Line Install

## Windows EXE App

Для пользователей Windows можно скачать `SolarHermes.exe` из GitHub Releases:

```text
https://github.com/RobotKSR/solar-hermes-company/releases/latest
```

Это пошаговое приложение:

1. Вставьте LLM Platform API token.
2. Дождитесь установки Hermes + Headroom.
3. Перейдите на отдельный экран чата и пишите сообщения.

Приложение само ставит/обновляет Hermes + Headroom и отправляет сообщения в Hermes через локальную команду:

```text
solar-hermes chat --query "<message>" --quiet
```

Ответ появляется прямо в окне приложения, отдельный PowerShell-чат и консольные окна не открываются.

Если раньше была ошибка `hermes: headroom executable not found`, скачайте свежий `SolarHermes.exe` и нажмите установку заново. Новый установщик сам bootstrap-ит `pip` внутри Hermes venv (`ensurepip`, затем fallback `get-pip.py`), ставит `headroom-ai[proxy]` только из binary wheels, проверяет установку `headroom-ai`, ищет `headroom.exe/headroom.cmd/headroom.ps1`, а если entrypoint не создан, запускает Headroom через `python -m headroom.cli`.

Если после установки была ошибка `401 could not validate credentials`, повторно запустите установку в свежем `SolarHermes.exe`. Установщик перепишет локальный `config.yaml`, чтобы Hermes отправлял в Headroom реальный LLM Platform token, а не placeholder `headroom-local`.

### macOS / Linux

```bash
curl -fsSL https://raw.githubusercontent.com/RobotKSR/solar-hermes-company/main/install.sh | bash
```

### Windows PowerShell

```powershell
irm https://raw.githubusercontent.com/RobotKSR/solar-hermes-company/main/install.ps1 | iex
```

Установщик попросит вставить API-токен из LLM Platform. После установки:

```bash
solar-hermes
```

На Windows установщик обновляет `PATH` внутри текущего процесса, поэтому перезапуск PowerShell не нужен. Если команда всё равно не найдена, запустите абсолютный путь:

```powershell
%USERPROFILE%\.solar-hermes\bin\solar-hermes.cmd
```

Windows installer автоматически ищет реальный Hermes home в таком порядке:

1. `$env:HERMES_HOME`
2. `%LOCALAPPDATA%\hermes`
3. `%USERPROFILE%\.hermes`

Поэтому он работает и с нативной Windows-установкой Hermes, и с WSL/Unix-like раскладкой.

## Что Делает Установщик

1. Ставит официальный Hermes Agent.
2. Ставит `headroom-ai[proxy,mcp]` в Python-окружение Hermes.
3. Сохраняет LLM Platform token в `~/.hermes/.env`.
4. Настраивает `~/.hermes/config.yaml`:

```yaml
model:
  default: qwen3.6
  provider: custom
  base_url: http://127.0.0.1:8787/v1
  api_key: <LLM Platform API token>
agent:
  max_tokens: 32768
  disable_api_streaming: true
display:
  streaming: false
compression:
  enabled: true
```

5. Создаёт команду `solar-hermes`.
6. При запуске `solar-hermes` стартует локальный Headroom proxy на `127.0.0.1:8787`, затем открывается чат Hermes.

Поток запросов:

```text
Hermes CLI
  -> Headroom proxy (local, 127.0.0.1:8787)
  -> https://llm.solar-group.com/v1
  -> Qwen/Qwen3.6-35B-A3B
```

## Где Взять Токен

1. Откройте LLM Platform.
2. Войдите доменной учётной записью.
3. Создайте fixed API token.
4. Вставьте token в установщик.

Формат авторизации:

```http
Authorization: Bearer <token>
```

## Смена Токена

Проще всего повторно запустить установщик. Или вручную изменить `OPENAI_API_KEY` в:

```text
~/.hermes/.env
```

## Обновление

Повторный запуск установщика:

- обновит Headroom;
- заново применит корпоративную конфигурацию;
- повторно применит маленький патч Hermes для стабильного non-streaming режима на длинных tool-call ответах.

## Почему Non-Streaming

Qwen/vLLM поддерживает streaming, и `llm.solar-group.com` тоже может проксировать `stream=true`. Но у Hermes на длинных tool-call ответах через `nginx -> FastAPI proxy -> vLLM` возможны `incomplete chunked read`. Поэтому корпоративная сборка использует стабильный non-streaming режим для основного LLM вызова, а Headroom всё равно работает локально как proxy сжатия контекста.

## Безопасность

- Headroom запускается локально на машине пользователя.
- Токен хранится локально в `~/.hermes/.env`.
- Не коммитьте `.env`, токены и содержимое `~/.hermes`.
- Если токен утёк, удалите его в LLM Platform и создайте новый.

## Проверка

```bash
solar-hermes --version
solar-hermes
```

Внутри Hermes задайте простой вопрос:

```text
Привет, какой ты моделью пользуешься?
```

Ожидаемо: Hermes отвечает через `qwen3.6`.
