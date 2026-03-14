FROM ruby:3.3-slim

RUN apt-get update -qq && \
    apt-get install -y --no-install-recommends build-essential curl && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY . .

RUN chmod +x bin/start

ENTRYPOINT ["bin/start"]
CMD ["web"]
