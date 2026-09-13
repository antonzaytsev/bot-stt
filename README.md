# bot-stt

Telegram bot that transcribes speech to text using OpenAI Whisper. Add it to a private channel — it listens for voice messages and audio uploads, transcribes them, and replies with the text. Managed entirely via Telegram commands, no web UI.

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

## Audio Uploads

Besides voice messages, the bot transcribes audio sent as a Telegram **audio** message or as a **document** (any `audio/*` file, or a file with an audio extension such as `.mp3`, `.m4a`, `.wav`, `.flac`, `.opus`).

- Every upload is normalised with ffmpeg and split into 10-minute chunks, so any container format and length works.
- The bot replies with a status message and edits it as it progresses.
- Transcripts up to 3500 characters are returned as text; longer ones are sent back as a `.txt` file named after the upload.
- Telegram bots can only download files up to 20 MB — larger uploads get a message saying so.
- 👎 re-transcription is only available for voice messages, not for audio uploads.

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
