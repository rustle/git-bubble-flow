# syntax=docker/dockerfile:1.7
#
# Build and test environment for git-bubble-flow.
#
#   dev     toolchain + git + bats + git-absorb + the Static Linux SDK.
#           This is the image the dev loop and CI run in.
#   build   compiles fully-static release binaries for both Linux arches.
#   dist    scratch image holding just those binaries, for `--output`.

ARG SWIFT_VERSION=6.3.3
ARG UBUNTU_RELEASE=noble

########################################################################
# git-absorb is a runtime dependency of `bubble-absorb` and the conformance
# suite. Upstream publishes no aarch64-linux binary and Ubuntu only carries
# 0.6.11, so build the version we actually target.
########################################################################
FROM rust:1-slim-bookworm AS absorb
ARG GIT_ABSORB_VERSION=0.9.0
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      build-essential cmake pkg-config libssl-dev ca-certificates \
 && rm -rf /var/lib/apt/lists/*
RUN cargo install git-absorb --locked --version "${GIT_ABSORB_VERSION}" --root /out

########################################################################
# Dev / CI image
########################################################################
FROM swift:${SWIFT_VERSION}-${UBUNTU_RELEASE} AS dev

ARG SWIFT_VERSION
# Pinned from swift.org's release metadata (www.swift.org/api/v1/install/releases.json).
# swift.org publishes no .sha256 sidecar, so the digest is carried here.
ARG STATIC_SDK_VERSION=0.1.0
ARG STATIC_SDK_CHECKSUM=87c3eaf908e67c0e13a84367119e12273cec1d2cd3d81f7d74bb36722d6b607b

# Ubuntu noble ships git 2.43. The tool needs 2.38 or newer (for
# `rebase --update-refs`), so the distribution package is deliberately good
# enough and no third-party PPA is pulled in.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      git bats jq curl ca-certificates \
 && rm -rf /var/lib/apt/lists/*

COPY --from=absorb /out/bin/git-absorb /usr/local/bin/git-absorb

# Static Linux SDK: cross-compiles to fully-static musl binaries for both
# x86_64 and aarch64, so a release links no Swift runtime at all.
RUN swift sdk install \
      "https://download.swift.org/swift-${SWIFT_VERSION}-release/static-sdk/swift-${SWIFT_VERSION}-RELEASE/swift-${SWIFT_VERSION}-RELEASE_static-linux-${STATIC_SDK_VERSION}.artifactbundle.tar.gz" \
      --checksum "${STATIC_SDK_CHECKSUM}" \
 && swift sdk list

# The test fixtures create throwaway repos and commit into them.
RUN git config --global user.name "Bubble Flow CI" \
 && git config --global user.email "ci@bubble-flow.invalid" \
 && git config --global init.defaultBranch main \
 # Scoped to the bind-mounted source tree, whose owner differs from the
 # container user. A blanket '*' would disable the ownership check everywhere.
 && git config --global --add safe.directory /workspace

WORKDIR /workspace
ENV BUBBLE_FLOW_IN_CONTAINER=1
CMD ["/bin/bash"]

########################################################################
# Static release build
########################################################################
FROM dev AS build
COPY Package.swift Package.resolved ./
COPY Sources ./Sources
COPY Tests ./Tests
RUN --mount=type=cache,target=/workspace/.build,sharing=locked \
    set -eux; \
    mkdir -p /dist; \
    for triple in aarch64-swift-linux-musl x86_64-swift-linux-musl; do \
      swift build -c release --swift-sdk "$triple" --product git-bubble-flow \
        -Xswiftc -gnone \
        -Xswiftc -Osize \
        -Xlinker --gc-sections \
        -Xlinker --strip-all; \
      arch="${triple%%-*}"; \
      install -m 0755 \
        ".build/${triple}/release/git-bubble-flow" \
        "/dist/git-bubble-flow-linux-${arch}"; \
    done; \
    ls -l /dist

########################################################################
# Extractable artifacts: `docker build --target dist --output type=local,dest=dist .`
########################################################################
FROM scratch AS dist
COPY --from=build /dist/ /
