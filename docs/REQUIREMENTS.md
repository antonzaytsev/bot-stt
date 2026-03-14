# Telegram Voice-to-Text Bot — Requirements

## Overview

A Telegram bot that monitors a private channel for voice messages, automatically transcribes them to text using a speech-to-text API, and replies with the transcription. The bot is managed entirely through the Telegram chat interface — no web frontend. A backend JSON API is exposed for health checks and operational monitoring.

## Prerequisites

Before setup, the following must be obtained:

| Item                  | How to obtain                                                                 |
|-----------------------|-------------------------------------------------------------------------------|
| **Telegram Bot Token** | Create a bot via [@BotFather](https://t.me/BotFather) and copy the token.    |
| **OpenAI API Key**     | Generate at [platform.openai.com/api-keys](https://platform.openai.com/api-keys). Requires an OpenAI account with billing enabled. |
| **Admin Telegram ID**  | Send a message to [@userinfobot](https://t.me/userinfobot) to get your numeric user ID. This is the user who receives error notifications and can issue admin commands. |
| **Docker & Docker Compose** | Must be installed on the host machine.                                  |

## Functional Requirements

### Core Behavior

- The bot is added to a single private Telegram channel (group/supergroup).
- When any user in the channel sends a voice message, the bot picks it up and transcribes it.
- The bot replies **to the original voice message** with the transcribed text.
- Only voice messages are processed. Video notes, audio files, and other media are ignored.
- All users in the channel are treated equally — no access control or whitelisting.

### Bot Commands (Telegram Interface)

The admin user can control and query the bot directly in Telegram via commands:

| Command      | Description                                                        |
|--------------|--------------------------------------------------------------------|
| `/status`    | Returns bot health: uptime, Redis connectivity, Sidekiq queue size |
| `/stats`     | Returns basic counters: messages processed today, failures today   |
| `/ping`      | Simple liveness check — bot replies "pong"                         |
| `/help`      | Lists available commands                                           |

- Commands are only accepted from the designated admin user (matched by `ADMIN_CHAT_ID`). Messages from other users are ignored.
- Command responses are sent as private messages to the admin, not in the channel.

### Language Support

- The bot auto-detects the spoken language — no manual language selection required.
- Must support a wide range of languages (multilingual).

### Error Handling

- If transcription fails (API error, timeout, unsupported format, etc.), the bot notifies the **admin user** via a private message with error details.
- The bot does not post error messages in the channel itself.

### Data Persistence

- No transcriptions are stored in a database. The bot is stateless in terms of message history.
- Redis is used only as a Sidekiq backend for job queue management.
- Basic in-memory counters (processed/failed counts, boot time) are kept for `/status` and `/stats` responses. These reset on restart.

## Backend API

A minimal JSON API is exposed by the Roda web app for operational purposes. No frontend is served.

| Endpoint         | Method | Description                                                   |
|------------------|--------|---------------------------------------------------------------|
| `/health`        | GET    | Returns `{ "status": "ok" }` — used by Docker healthcheck    |
| `/webhook`       | POST   | Telegram webhook endpoint — receives updates from Telegram    |

- No authentication on `/health` (public liveness probe).
- `/webhook` is verified by Telegram's built-in request signing (secret token).
- No other routes are served. Requests to unknown paths return 404.

## Non-Functional Requirements

### Speech-to-Text Provider

**OpenAI Whisper API** (`whisper-1` model) is selected as the STT provider:

- Industry-leading accuracy across 90+ languages with automatic language detection.
- Simple API: send audio file, receive text.
- Reasonable cost ($0.006/minute of audio).
- User provides their own OpenAI API key.

### Tech Stack

| Component       | Technology        |
|-----------------|-------------------|
| Language        | Ruby              |
| Web framework   | Roda              |
| Background jobs | Sidekiq           |
| Job queue store | Redis             |
| STT API         | OpenAI Whisper    |
| Deployment      | Docker Compose    |

### Processing Model

- Voice messages are received via Telegram webhook (delivered to the Roda web app).
- Transcription is performed asynchronously in a Sidekiq background job to avoid blocking the webhook response.
- Flow: **Webhook received → Sidekiq job enqueued → Audio downloaded from Telegram → Sent to Whisper API → Reply posted to channel.**

### Deployment

- Packaged as Docker containers orchestrated with Docker Compose.
- Services: web (Roda app), worker (Sidekiq), Redis.
- No frontend, no static assets, no HTML served.
- Configuration via environment variables loaded from `.env` file.

### Development Experience

- **Live reload:** App code is mounted into containers via a bind mount. File changes on the host are reflected immediately using a file-watching reloader (e.g. `rerun` or Puma's built-in restart) — no rebuild required.
- **Bundle volume:** A named Docker volume is used for the gem bundle (`/usr/local/bundle`). Gems persist across container restarts and rebuilds, avoiding repeated `bundle install` on every start.
- **No `bundle install` in Dockerfile:** The Dockerfile does **not** run `bundle install` during image build. Instead, a `bin/start` entrypoint script runs `bundle install` (fast no-op when gems are cached in the volume) and then starts the app. This keeps the image lightweight and lets gem changes be picked up without rebuilding.
- **Start script (`bin/start`):** Entrypoint for both web and worker services. Runs `bundle install`, then exec's the target process (Puma for web, Sidekiq for worker). Accepts the process type as an argument.

### Port Configuration

- The app port is configured via the `PORT` environment variable in the `.env` file.
- Docker Compose maps the same port for both host and container (`${PORT}:${PORT}`).
- Puma binds to `0.0.0.0:${PORT}`.

## Configuration

The following environment variables are required (defined in `.env`):

| Variable              | Description                                      |
|-----------------------|--------------------------------------------------|
| `TELEGRAM_BOT_TOKEN`  | Bot API token from BotFather                    |
| `OPENAI_API_KEY`      | OpenAI API key for Whisper                      |
| `ADMIN_CHAT_ID`       | Telegram user ID to receive error notifications and admin commands |
| `REDIS_URL`           | Redis connection URL for Sidekiq                |
| `WEBHOOK_SECRET`      | Secret token for Telegram webhook verification  |
| `PORT`                | App port — used for both host and container mapping (e.g. `3000`) |

## Out of Scope (v1)

- Transcription history or database storage.
- Web frontend or admin UI.
- Transcribing video notes or audio files.
- Multi-channel support (bot serves one channel).
- User-level access control or permissions.
- Message editing or re-transcription.
