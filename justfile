# Displays available recipes by running `just -l`.
setup:
  #!/usr/bin/env bash
  just -l

# Install local tools used by formatting and lint checks.
install:
  #!/usr/bin/env bash
  set -euo pipefail
  rustup component add rustfmt clippy
  go install mvdan.cc/gofumpt@v0.4.0
  GO111MODULE=on go install mvdan.cc/sh/v3/cmd/shfmt@v3.7.0
  if ! command -v shellcheck >/dev/null 2>&1; then
    if command -v apt-get >/dev/null 2>&1; then
      sudo apt-get update
      sudo apt-get install --no-install-recommends -y shellcheck
    else
      echo "shellcheck is required but was not found on PATH" >&2
      exit 1
    fi
  fi

alias i := install

# Build Go and Rust libraries.
build:
  make build

alias b := build

# Build the Rust libwasmvm shared library.
build-rust:
  make build-rust

# Build Go packages and demo.
build-go:
  make build-go

# Format Rust, Go, and shell files.
fmt:
  #!/usr/bin/env bash
  set -euo pipefail
  (cd libwasmvm && cargo fmt)
  gofumpt -w -s .
  shfmt -w .

# Check Rust, Go, and shell formatting.
fmt-check:
  just rust-fmt-check
  just go-fmt-check
  just scripts-fmt-check

# Check Rust formatting.
rust-fmt-check:
  (cd libwasmvm && cargo fmt -- --check)

# Check Go formatting.
go-fmt-check:
  #!/usr/bin/env bash
  set -euo pipefail
  [ "$(gofmt -l .)" = "" ] || (gofmt -d . && exit 1)
  [ "$(gofumpt -l .)" = "" ] || (gofumpt -d . && exit 1)

# Check shell formatting.
scripts-fmt-check:
  #!/usr/bin/env bash
  set -euo pipefail
  shfmt --diff .

# Run Rust clippy.
clippy:
  (cd libwasmvm && cargo clippy --all-targets -- -D warnings)

alias lint := clippy

# Run Rust unit tests.
test:
  (cd libwasmvm && cargo test)

alias t := test

# Run Go tests.
test-go:
  make test

# Run Go tests with cgo race-safety checks.
test-go-safety:
  make test-safety

# Build and test without cgo.
test-no-cgo:
  #!/usr/bin/env bash
  set -euo pipefail
  CGO_ENABLED=0 go build ./types
  CGO_ENABLED=0 go build .
  CGO_ENABLED=0 go test ./types
  CGO_ENABLED=0 go test .

# Build Rust docs.
doc:
  (cd libwasmvm && cargo doc --no-deps)

# Run Rust doc tests without leaving Cargo.toml modified.
doc-test:
  #!/usr/bin/env bash
  set -euo pipefail
  cd libwasmvm
  cp Cargo.toml Cargo.toml.bak
  restore_manifest() {
    mv Cargo.toml.bak Cargo.toml
  }
  trap restore_manifest EXIT
  sed -i '/^crate-type = \["cdylib"\]/d' Cargo.toml
  cargo test --doc

# Run cargo audit.
audit:
  (cd libwasmvm && cargo audit)

# Run cargo check and fail if libwasmvm/bindings.h changed.
check:
  #!/usr/bin/env bash
  set -euo pipefail
  (cd libwasmvm && cargo check)
  changes="$(git status --porcelain libwasmvm/bindings.h)"
  if [ -n "$changes" ]; then
    echo "libwasmvm/bindings.h changed. Run 'make update-bindings' and commit the result." >&2
    git status
    git --no-pager diff -- libwasmvm/bindings.h
    exit 1
  fi

# Check generated bindings copied into internal/api.
bindings-check:
  diff libwasmvm/bindings.h internal/api/bindings.h

# Check go.mod/go.sum are tidy.
go-tidy-check:
  #!/usr/bin/env bash
  set -euo pipefail
  go mod tidy
  changes="$(git status --porcelain)"
  if [ -n "$changes" ]; then
    echo "Repository is dirty after 'go mod tidy'." >&2
    git status
    git --no-pager diff
    exit 1
  fi

# Run shellcheck over tracked shell scripts.
shellcheck:
  #!/usr/bin/env bash
  set -euo pipefail
  git ls-files '*.sh' | xargs -r shellcheck

# Build the static musl Docker builder image.
docker-image-static:
  docker build --pull --progress=plain --platform=linux/amd64 builders -t cosmwasm/go-ext-builder:0018-alpine -f builders/Dockerfile.alpine

# Build the Linux shared Docker builder image.
docker-image-linux:
  docker build --pull --progress=plain --platform=linux/amd64 builders -t cosmwasm/go-ext-builder:0018-debian -f builders/Dockerfile.debian

# Build the Darwin and Windows cross Docker builder image.
docker-image-cross:
  docker build --pull --progress=plain builders -t cosmwasm/go-ext-builder:0018-cross -f builders/Dockerfile.cross

# Build static musl release artifacts.
artifact-static:
  make release-build-alpine

# Build Linux shared release artifacts.
artifact-linux:
  #!/usr/bin/env bash
  set -euo pipefail
  rm -rf libwasmvm/target/x86_64-unknown-linux-gnu/release
  rm -rf libwasmvm/target/aarch64-unknown-linux-gnu/release
  docker run --rm -u "$(id -u):$(id -g)" -v "$PWD/libwasmvm:/code" cosmwasm/go-ext-builder:0018-debian build_linux.sh
  cp libwasmvm/artifacts/libwasmvm.x86_64.so internal/api
  cp libwasmvm/artifacts/libwasmvm.aarch64.so internal/api
  just update-bindings

# Build Darwin shared and static release artifacts.
artifact-darwin:
  make release-build-macos
  make release-build-macos-static

# Run the libwasmvm release helper. Use this to install deps, test the helper,
# dry-run publishing, print the next tag, or run a real GitHub Release publish.
release *args:
  #!/usr/bin/env bash
  set -euo pipefail
  (cd scripts && bun install --frozen-lockfile)
  bun run scripts/releaseArtifacts.ts {{args}}


# Copy generated Rust bindings into the Go package.
update-bindings:
  cp libwasmvm/bindings.h internal/api

# Run Rust PR checks.
ci-rust:
  just check
  just bindings-check
  just test
  just doc
  just doc-test

# Run Go PR checks.
ci-go:
  just go-fmt-check
  just go-tidy-check
  just test-no-cgo

# Run shell script PR checks.
ci-scripts:
  just scripts-fmt-check
  just shellcheck

# Format, lint, and test.
tidy:
  just ci-rust
  just clippy
  just ci-go
  just ci-scripts
