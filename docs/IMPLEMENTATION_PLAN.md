# Implementation Plan

Ordered sequence of steps to build the bot from an empty project to a running Docker deployment.

---

## Phase 1 — Project Skeleton

**Goal:** Bootable Ruby app with Roda, Sidekiq, and Redis wired together.

1. Initialize project structure:

```
├── Gemfile
├── Rakefile
├── config.ru
├── .env.example
├── Dockerfile
├── docker-compose.yml
├── bin/
│   └── start              # Entrypoint script: runs bundle install, then starts process
├── app.rb                  # Roda application
├── config/
│   ├── environment.rb      # Loads env vars, configures dependencies
│   └── sidekiq.rb          # Sidekiq client/server config
├── lib/
│   ├── bot/
│   │   ├── telegram_client.rb
│   │   ├── whisper_client.rb
│   │   ├── command_handler.rb
│   │   └── stats.rb
│   └── jobs/
│       └── transcribe_job.rb
└── docs/
```

2. Create `Gemfile` with dependencies: `roda`, `sidekiq`, `puma`, `httpx` (HTTP client for Telegram & OpenAI APIs), `oj` (fast JSON), `dotenv`, `rerun` (live reload in development).
3. Create `config/environment.rb` — loads `.env` in development, validates required env vars are present, freezes config into a simple module/struct.
4. Create `config.ru` and minimal `app.rb` — Roda app that boots and responds to `GET /health` with `{ "status": "ok" }`. Puma binds to `0.0.0.0:${PORT}`.
5. Create `config/sidekiq.rb` — connects Sidekiq to Redis.
6. Create `bin/start` — entrypoint script that runs `bundle install` then exec's the target process. Usage: `bin/start web` (Puma with live reload via `rerun`) or `bin/start worker` (Sidekiq).
7. Verify: `bin/start web` starts, `/health` returns 200. `bin/start worker` connects to Redis.

---

## Phase 2 — Telegram Webhook Endpoint

**Goal:** Receive Telegram updates and parse them.

1. Create `lib/bot/telegram_client.rb` — thin wrapper around Telegram Bot API using `httpx`. Methods: `send_message`, `reply_to_message`, `get_file`, `download_file`, `set_webhook`.
2. Add `POST /webhook` route in `app.rb`:
   - Verify `X-Telegram-Bot-Api-Secret-Token` header matches `WEBHOOK_SECRET`.
   - Parse JSON body.
   - Distinguish between voice messages and bot commands.
   - For voice messages → enqueue `TranscribeJob`.
   - For commands from admin → delegate to `CommandHandler`.
   - Return 200 immediately in all cases (Telegram expects fast response).
3. Create a Rake task `rake bot:set_webhook` that calls Telegram's `setWebhook` API with the app's public URL and secret token.
4. Verify: send a test webhook payload with curl, confirm job is enqueued in Sidekiq.

---

## Phase 3 — Transcription Job

**Goal:** Download voice audio, send to Whisper, reply with text.

1. Create `lib/jobs/transcribe_job.rb` (Sidekiq worker):
   - Accept `chat_id`, `message_id`, `file_id` as arguments.
   - Call Telegram `getFile` API to get the file path.
   - Download the OGG audio file from Telegram's file storage.
   - Send audio to OpenAI Whisper API (`POST /v1/audio/transcriptions`).
   - Reply to the original message with the transcription text.
   - On failure: catch exceptions, notify admin via private message with error details.
   - Increment in-memory stats counters (success/failure).
2. Create `lib/bot/whisper_client.rb` — wraps OpenAI audio transcription endpoint. Sends multipart form with the audio file, returns text.
3. Configure Sidekiq retry: 2 retries with backoff, then dead queue.
4. Verify: enqueue a job manually with a real file_id, confirm transcription appears as a reply.

---

## Phase 4 — Bot Commands

**Goal:** Admin can query bot status via Telegram commands.

1. Create `lib/bot/stats.rb` — singleton that tracks:
   - Boot timestamp (for uptime calculation).
   - Today's processed count and failure count (reset daily or on restart).
2. Create `lib/bot/command_handler.rb`:
   - Receives parsed command and user ID.
   - Rejects if sender is not `ADMIN_CHAT_ID`.
   - `/ping` → replies "pong".
   - `/status` → replies with uptime, Redis ping, Sidekiq queue size.
   - `/stats` → replies with processed/failed counts for today.
   - `/help` → replies with list of available commands.
   - Sends responses as private messages to admin.
3. Verify: send `/status` from admin account, confirm response. Send from non-admin, confirm silence.

---

## Phase 5 — Docker & Deployment

**Goal:** One-command deploy with `docker compose up`.

1. Create `Dockerfile`:
   - Ruby base image.
   - **No `bundle install`** — gems are installed at container start via `bin/start`.
   - Copy app code.
   - Set `bin/start` as the entrypoint.
2. Create `docker-compose.yml`:
   - **web** service: runs `bin/start web`, depends on Redis.
     - Bind mount for app source code (live reload — file changes reflected without rebuild).
     - Named volume for bundle (`/usr/local/bundle`) — gems persist across restarts.
     - Port mapping: `${PORT}:${PORT}` (both values from `.env`).
     - Healthcheck on `/health`.
   - **worker** service: runs `bin/start worker`, same image, depends on Redis.
     - Same bind mount and bundle volume as web.
   - **redis** service: official Redis image with volume for data persistence.
   - All services use `env_file: .env`.
3. Create `.env.example` with all required variables documented, including `PORT`.
4. Verify: `docker compose up --build` starts all services, webhook is reachable, full flow works end-to-end. Edit a Ruby file on host → confirm live reload picks it up.

---

## Phase 6 — Hardening

**Goal:** Production readiness.

1. Add request logging (Roda plugin or middleware) — log webhook receipts and API calls.
2. Add structured error handling in the transcribe job — distinguish between Telegram API errors, OpenAI API errors, and network timeouts with different admin notification messages.
3. Add Sidekiq dead job handler — notify admin when a job exhausts all retries.
4. Add graceful shutdown handling — Sidekiq and Puma respond to SIGTERM properly (default behavior, but verify in Docker).
5. Add `.dockerignore` to exclude docs, `.env`, `.git`.
6. Final end-to-end test: send voice message in channel → receive transcription reply. Send `/status` → receive health report. Kill Whisper API temporarily → receive error notification.
