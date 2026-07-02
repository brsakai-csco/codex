FROM ubuntu:22.04

ARG DEBIAN_FRONTEND=noninteractive
# enable 'universe' because musl-tools & clang live there
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    software-properties-common && \
    add-apt-repository --yes universe

# now install build deps
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    build-essential curl git ca-certificates \
    pkg-config libcap-dev clang musl-tools libssl-dev && \
    rm -rf /var/lib/apt/lists/*

ARG USER_UID=1000
ARG USER_GID=1000
RUN groupadd --gid "${USER_GID}" ubuntu && \
    useradd --uid "${USER_UID}" --gid "${USER_GID}" --create-home --shell /bin/bash ubuntu

USER ubuntu

# install Rust + musl target as dev user
RUN curl -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal && \
    ~/.cargo/bin/rustup target add aarch64-unknown-linux-musl && \
    ~/.cargo/bin/rustup component add clippy rustfmt && \
    ~/.cargo/bin/cargo install --locked just && \
    ~/.cargo/bin/cargo install --locked cargo-nextest

ENV PATH="/home/ubuntu/.cargo/bin:${PATH}"

WORKDIR /workspace
