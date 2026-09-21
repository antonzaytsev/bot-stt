# bot-stt

Telegram bot that transcribes speech to text using OpenAI Whisper. Add it to a private channel — it listens for voice messages, audio uploads and YouTube links, transcribes them, replies with the text and offers a summary. Managed entirely via Telegram commands, no web UI.

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

## YouTube Links and Other Media

Post a YouTube link in an allowed chat and the bot transcribes its audio — no captions are used, the audio always goes through Whisper. `/summarize <url>` runs the same pipeline for any site yt-dlp supports (podcasts, direct mp3 links) and summarizes without being asked.

- The transcript always comes back as a `.txt` file named after the media, captioned with title, duration and size.
- Media longer than `MEDIA_CONFIRM_MINUTES` (default 30) is not processed until you tap **Proceed**; the bot shows the duration and the estimated Whisper cost first.
- Live streams, upcoming premieres and playlists are refused.
- Transcripts and summaries are cached for 90 days per media identity (`extractor:id`), refreshed on each use. The same video posted twice — by anyone, in any chat, under any URL shape — costs nothing the second time.

## Summaries

Any transcript long enough to be worth summarizing (1000+ characters, and every media transcript) comes with a **Summarize** button. Tapping it produces a TL;DR, topic sections and notable specifics, in the transcript's own language.

- Under ~24k characters the transcript is summarized in a single pass with `SUMMARY_MODEL` (default `gpt-4o`).
- Longer transcripts are mapped into dense per-window notes with `gpt-4o-mini` and then reduced into the final summary — one big prompt into a small model produces a shallow summary, which is what this avoids.
- Summaries over ~3800 characters arrive as `<title>-summary.txt`.
- The button is removed once tapped, and a second tap never pays for the same summary twice.
- Markdown from the model is converted to Telegram HTML before sending; if Telegram still rejects the entities, the same summary goes out unformatted rather than not at all.

## Costs

Every transcript and summary says what it cost at OpenAI list prices — audio minutes at $0.006/min plus the actual token usage the API reports for the formatting and summary passes.

- Media transcripts put the figure in the file caption: `Title · 12m · 10000 characters · $0.14`.
- A summary ends with `Cost: $0.18 (transcript $0.14 + summary $0.04)`, so the total for that video is visible in one line.
- Cache hits say so and cost nothing.
- Audio uploads show a cost only when Telegram reports a duration; for arbitrary documents it does not, and a figure that leaves out the audio minutes would be misleading.

## Bot Commands

Send these to the bot in Telegram (admin only):

| Command   | Description                          |
|-----------|--------------------------------------|
| `/ping`   | Liveness check                       |
| `/status` | Uptime, Redis, Sidekiq queue         |
| `/stats`  | Processed/failed counts today        |
| `/help`   | List commands                        |
| `/summarize <url>` | Transcribe and summarize media at a URL |

## Tests

```bash
RACK_ENV=test bundle exec rake test
```

## Stack

Ruby, Roda, Puma, Sidekiq, Redis, OpenAI Whisper API, Docker Compose.
