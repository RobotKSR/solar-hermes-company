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
solar-hermes chat --query "<message>"
```

Ответ появляется прямо в окне приложения в режиме live stream, отдельный PowerShell-чат и консольные окна не открываются. Если Hermes запрашивает подтверждение действия, приложение показывает кнопки `Разрешить 1 раз`, `Разрешить на сессию`, `Всегда разрешать`, `Отклонить` и отправляет выбранный ответ обратно в активный Hermes-процесс.

Если раньше была ошибка `hermes: headroom executable not found`, скачайте свежий `SolarHermes.exe` и нажмите установку заново. Новый установщик сам bootstrap-ит `pip` внутри Hermes venv (`ensurepip`, затем fallback `get-pip.py`), ставит `headroom-ai[proxy]` только из binary wheels, проверяет установку `headroom-ai`, ищет `headroom.exe/headroom.cmd/headroom.ps1`, а если entrypoint не создан, запускает Headroom через `python -m headroom.cli`.

Если после установки была ошибка `401 could not validate credentials`, повторно запустите установку в свежем `SolarHermes.exe`. Установщик перепишет локальный `config.yaml`, чтобы Hermes отправлял в Headroom реальный LLM Platform token, а не placeholder `headroom-local`.

### macOS / Linux (CLI)

```bash
curl -fsSL https://raw.githubusercontent.com/RobotKSR/solar-hermes-company/main/install.sh | bash
```

Без интерактивного ввода токена:

```bash
LLM_PLATFORM_TOKEN="<token>" curl -fsSL https://raw.githubusercontent.com/RobotKSR/solar-hermes-company/main/install.sh | bash
```

### Windows PowerShell (CLI)

```powershell
irm https://raw.githubusercontent.com/RobotKSR/solar-hermes-company/main/install.ps1 | iex
```

Без интерактивного ввода токена:

```powershell
$env:LLM_PLATFORM_TOKEN="<token>"; irm https://raw.githubusercontent.com/RobotKSR/solar-hermes-company/main/install.ps1 | iex
```

Установщик спрашивает API-токен **в самом начале**, до установки Hermes и Headroom. После установки:

```bash
solar-hermes
```

Одно сообщение без интерактивного чата:

```bash
solar-hermes chat --query "Привет, какой ты моделью пользуешься?"
```

В CLI Hermes сам показывает streaming-ответ и запрашивает подтверждения опасных действий в терминале — поведение то же, что и в `SolarHermes.exe`, только без отдельного GUI.

На Windows установщик обновляет `PATH` внутри текущего процесса, поэтому перезапуск PowerShell не нужен. Если команда всё равно не найдена, запустите абсолютный путь:

```powershell
%USERPROFILE%\.solar-hermes\bin\solar-hermes.cmd
```

На macOS/Linux команда ставится в `~/.local/bin/solar-hermes`. Если shell её не видит:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

### Поиск Hermes home

Windows installer автоматически ищет реальный Hermes home в таком порядке:

1. `$env:HERMES_HOME`
2. `%LOCALAPPDATA%\hermes`
3. `%USERPROFILE%\.hermes`

macOS/Linux installer ищет:

1. `$HERMES_HOME`
2. `~/.hermes`

### Типичные ошибки CLI

| Ошибка | Что делать |
|--------|------------|
| `headroom executable not found` | Повторно запустите установщик. Он bootstrap-ит `pip` (`ensurepip` → `get-pip.py`), ставит `headroom-ai[proxy]`, проверяет `import headroom.cli` и при отсутствии `headroom` бинарника запускает `python -m headroom.cli`. |
| `401 could not validate credentials` | Повторно запустите установщик с актуальным токеном. Установщик перепишет `config.yaml`, чтобы `model.api_key` был реальным LLM Platform token, а не placeholder. |
| `no session found matching` | Не используйте `--continue` с фиксированным именем сессии. Для одного сообщения: `solar-hermes chat --query "..."`. |
| `hermes -z: no final response` | Не используйте `--oneshot/-z`. Для CLI и GUI используется `chat --query`. |

## Что Делает Установщик

1. Спрашивает LLM Platform token (или берёт из `LLM_PLATFORM_TOKEN`).
2. Ставит официальный Hermes Agent, если его ещё нет.
3. Bootstrap-ит `pip` в Hermes venv, если нужно.
4. Ставит `headroom-ai[proxy]` в Python-окружение Hermes и проверяет `import headroom.cli`.
5. Сохраняет LLM Platform token в Hermes `.env`.
6. Настраивает `~/.hermes/config.yaml`:

```yaml
model:
  default: qwen3.6
  provider: custom
  base_url: http://127.0.0.1:8787/v1
  api_key: <LLM Platform API token>
agent:
  max_tokens: 32768
  disable_api_streaming: false
display:
  streaming: true
compression:
  enabled: true
```

7. Создаёт команду `solar-hermes` с fallback-запуском Headroom через `python -m headroom.cli`.
8. При запуске `solar-hermes` стартует локальный Headroom proxy на `127.0.0.1:8787`, затем открывается чат Hermes.

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
- повторно применит маленький патч Hermes, чтобы config мог управлять streaming/max_tokens.

## Streaming

И CLI, и Windows GUI используют streaming (`display.streaming: true`, `agent.disable_api_streaming: false`), чтобы ответ Hermes был виден по мере генерации. Если конкретная сеть или прокси начинает рвать long-running streaming responses, можно временно вернуть `agent.disable_api_streaming: true` и `display.streaming: false` в локальном `config.yaml`.

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
