FROM hexpm/elixir:1.19.5-erlang-28.5-alpine-3.23.4 AS build
WORKDIR /src
ENV MIX_ENV=prod

RUN apk add --no-cache patch && mix local.hex --force && mix local.rebar --force
COPY mix.exs mix.lock ./
COPY mix/ mix/
COPY config/ config/
RUN mix deps.get --only prod --check-locked && mix deps.compile
COPY lib/ lib/
COPY rel/ rel/
RUN mix compile --warnings-as-errors && mix release

FROM alpine:3.23.4
RUN apk add --no-cache ca-certificates libstdc++ ncurses-libs libcrypto3
WORKDIR /app
COPY --from=build /src/_build/prod/rel/ex_cable/ ./
ENV EX_CABLE_BIND=0.0.0.0 RELEASE_DISTRIBUTION=none RELEASE_TMP=/tmp
USER nobody:nogroup
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s \
  CMD wget -q -Y off -O /dev/null "http://127.0.0.1:${PORT:-8080}/healthz" || exit 1
CMD ["/app/bin/ex_cable", "start"]
