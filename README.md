# bot-stt

Telegram bot that transcribes voice messages to text using OpenAI Whisper. Add it to a private channel — it listens for voice messages, transcribes them, and replies with the text. Managed entirely via Telegram commands, no web UI.

Uses **long polling** — no public URL or webhook setup needed.

## Prerequisites

- Docker & Docker Compose
- Telegram bot token (from [@BotFather](https://t.me/BotFather))
- OpenAI API key (from [platform.openai.com](https://platform.openai.com/api-keys))
- Your Telegram user ID (from [@userinfobot](https://t.me/userinfobot))

## Setup

Run the interactive setup script:

```bash
bin/setup
```

This will create your `.env` file, prompt for required keys, and build the containers.

Or set up manually:

```bash
cp .env.example .env
# Edit .env with your values
docker compose build
```

## Run

```bash
docker compose up
```

This starts 4 services: **web** (health endpoint), **poller** (Telegram long polling), **worker** (Sidekiq), **redis**.

## Bot Commands

Send these to the bot in Telegram (admin only):

| Command   | Description                          |
|-----------|--------------------------------------|
| `/ping`   | Liveness check                       |
| `/status` | Uptime, Redis, Sidekiq queue         |
| `/stats`  | Processed/failed counts today        |
| `/help`   | List commands                        |

## Tests

```bash
RACK_ENV=test bundle exec rake test
```

## Stack

Ruby, Roda, Puma, Sidekiq, Redis, OpenAI Whisper API, Docker Compose.
