# Multi-stage production/release image (issue #026).
#
# Also the official self-hosting path for Amanogawa (ADR 0008, AGPL-3.0):
# this file stays generic on purpose, no value specific to any particular
# deployment is hardcoded here. Everything that varies by environment
# (database URL, secret key base, public hostname) is read at runtime from
# the environment (`config/runtime.exs`), never baked into the image.
#
# Builder base: https://hub.docker.com/r/hexpm/elixir/tags
# Runtime base: https://hub.docker.com/_/debian/tags
#
# Both pinned to the exact Elixir/OTP versions in `.tool-versions` and the
# same dated Debian Bookworm snapshot, so the builder's and the runtime's
# system libraries (glibc, libstdc++) come from the same snapshot and stay
# ABI-compatible.

ARG ELIXIR_VERSION=1.19.5
ARG OTP_VERSION=28.5.0.3
ARG DEBIAN_SNAPSHOT=bookworm-20260713

ARG BUILDER_IMAGE="docker.io/hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_SNAPSHOT}-slim"
ARG RUNNER_IMAGE="docker.io/debian:${DEBIAN_SNAPSHOT}-slim"

# ---------------------------------------------------------------------------
# Builder: compiles the release and the frontend assets, never shipped.
# ---------------------------------------------------------------------------
FROM ${BUILDER_IMAGE} AS builder

# build-essential: compiles NIFs (geo_postgis' dependencies) and Erlang C
# sources at `mix deps.compile`. git: required by mix.exs' heroicons
# dependency (`github:` source). nodejs/npm: `assets/package.json`
# (maplibre-gl, d3) is installed and bundled by esbuild at `mix
# assets.deploy`, not by the Elixir toolchain alone.
RUN apt-get update -y \
  && apt-get install -y --no-install-recommends build-essential git nodejs npm \
  && apt-get clean \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app

RUN mix local.hex --force \
  && mix local.rebar --force

ENV MIX_ENV="prod"

# Dependencies first: this layer only invalidates when mix.exs/mix.lock
# change, not on every source edit.
COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV

# Compile-time config before compiling dependencies, mirroring `mix
# phx.gen.release`'s own staged COPY order: config/runtime.exs is read at
# *boot*, not at compile time, so it is copied later and never invalidates
# this layer.
COPY config/config.exs config/${MIX_ENV}.exs config/
RUN mix deps.compile

COPY priv priv
COPY lib lib
RUN mix compile

# The npm lockfile lives under assets/, its own dependency layer.
COPY assets/package.json assets/package-lock.json assets/
RUN mix tailwind.install --if-missing \
  && mix esbuild.install --if-missing \
  && npm --prefix assets ci --no-fund --no-audit

COPY assets assets
RUN mix assets.deploy

COPY config/runtime.exs config/
COPY rel rel
RUN mix release

# ---------------------------------------------------------------------------
# Runtime: the compiled release only, no build toolchain, no source.
# ---------------------------------------------------------------------------
FROM ${RUNNER_IMAGE} AS runtime

# libstdc++6/openssl: required by the Erlang runtime and Postgrex's TLS
# support. ca-certificates: outbound HTTPS to Wikidata/Wikipedia
# (`Amanogawa.Ingestion`). locales: UTF-8 locale for the BEAM.
RUN apt-get update -y \
  && apt-get install -y --no-install-recommends \
    libstdc++6 openssl ca-certificates locales \
  && apt-get clean \
  && rm -rf /var/lib/apt/lists/*

RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen

ENV LANG=en_US.UTF-8 \
  LANGUAGE=en_US:en \
  LC_ALL=en_US.UTF-8 \
  MIX_ENV="prod" \
  HOME="/app"

WORKDIR /app

# Dedicated non-root user with a fixed uid/gid (issue #026): a fixed id,
# rather than an existing "nobody", so a bind-mounted volume's ownership
# stays predictable across image rebuilds and across hosts.
RUN groupadd --gid 10001 amanogawa \
  && useradd --uid 10001 --gid amanogawa --home-dir /app --shell /usr/sbin/nologin amanogawa

COPY --from=builder --chown=amanogawa:amanogawa /app/_build/${MIX_ENV}/rel/amanogawa ./

USER amanogawa

EXPOSE 4000

ENTRYPOINT ["/app/bin/docker-entrypoint"]
CMD ["start"]
