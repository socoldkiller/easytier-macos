FROM rust:1.88-bookworm AS builder
WORKDIR /src
COPY Cargo.toml Cargo.lock ./
COPY src ./src
RUN cargo build --locked --release

FROM debian:bookworm-slim
RUN apt-get update \
    && apt-get install --yes --no-install-recommends ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*
COPY --from=builder /src/target/release/easytier-native-sso-sidecar /usr/local/bin/
USER 65532:65532
ENTRYPOINT ["easytier-native-sso-sidecar"]
