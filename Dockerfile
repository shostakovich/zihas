FROM ruby:4.0-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential \
      libsqlite3-dev \
      tzdata \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY Gemfile Gemfile.lock ./
RUN bundle config set --local deployment 'true' \
 && bundle config set --local without 'test' \
 && bundle install --jobs 4

COPY . .

VOLUME ["/data"]
ENV DATABASE_PATH=/data/ziwoas.db \
    CONFIG_PATH=/app/config/ziwoas.yml \
    TZ=Europe/Berlin \
    RACK_ENV=production

EXPOSE 4567

CMD ["bundle", "exec", "puma", "-p", "4567", "-e", "production", "config.ru"]
