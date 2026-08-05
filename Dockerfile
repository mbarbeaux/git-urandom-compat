# syntax=docker/dockerfile:1

# ==============================================================================
# Compiles a statically-linked Git binary from source, patched to fall back to
# /dev/urandom instead of calling getrandom(2) directly -- that syscall is
# only available since Linux 3.17 and Git has called it unconditionally
# (with no fallback) since 2.36, breaking Git on older kernels (e.g. many
# Synology NAS models still on kernel 3.10). See CLAUDE.md for the full
# root-cause analysis.
#
# Built once per Git release here (GIT_VERSION build-arg, required) and
# consumed by forgejo-urandom-compat / gitea-urandom-compat via COPY --from=,
# instead of each of them recompiling the same Git source independently --
# in practice, many consecutive Forgejo/Gitea releases bundle the exact same
# Git version, so recompiling per-release was pure waste.
# ==============================================================================
FROM alpine:latest AS builder

# Build dependencies. On recent Alpine releases, static libraries (.a files)
# were split out of the regular -dev packages into dedicated -static
# packages, so both are needed for a fully static link.
#
# linux-headers: Git 2.55.0 added a Linux fsmonitor backend
# (config.mak.uname) that -- for ANY system detected as "Linux" --
# unconditionally adds `-DHAVE_LINUX_MAGIC_H` to BASIC_CFLAGS, regardless
# of whether that header is actually present. This is the exact same
# "config.mak.uname forces a flag for Linux no matter what" trap as
# CSPRNG_METHOD (see below), just for a different feature and a Git
# version that didn't exist when this Dockerfile was first written --
# without linux-headers, the build fails with "fatal error: linux/
# magic.h: No such file or directory" compiling
# compat/fsmonitor/fsm-path-utils-linux.c, on every Git release from
# 2.55.0 onward.
RUN apk add --no-cache \
        build-base \
        autoconf \
        pkgconf \
        curl \
        curl-dev \
        curl-static \
        expat-dev \
        expat-static \
        pcre2-dev \
        pcre2-static \
        zlib-dev \
        zlib-static \
        openssl-dev \
        openssl-libs-static \
        nghttp2-static \
        brotli-static \
        zstd-static \
        libpsl-static \
        libidn2-static \
        libunistring-static \
        linux-headers

ARG GIT_VERSION
RUN test -n "${GIT_VERSION}" || (echo "GIT_VERSION build-arg is required" >&2 && exit 1)

WORKDIR /usr/src
RUN curl -fsSL "https://github.com/git/git/archive/refs/tags/v${GIT_VERSION}.tar.gz" \
        -o git.tar.gz \
    && tar xzf git.tar.gz \
    && mv "git-${GIT_VERSION}" git

WORKDIR /usr/src/git

# Same critical options as forgejo-urandom-compat's original recipe:
# - CSPRNG_METHOD="" (explicitly empty): Git's own config.mak.uname
#   automatically forces CSPRNG_METHOD=getrandom for any system detected as
#   "Linux", regardless of whether we set it ourselves -- it must be
#   explicitly overridden on the make command line (which always takes
#   priority over an in-Makefile assignment) to force the /dev/urandom
#   fallback path instead of getrandom(2).
# - LDFLAGS="-static" -> fully self-contained binary, no runtime dependency
#   on musl/libcurl/etc. This is also what makes it safe to copy this
#   binary into a downstream image built from a DIFFERENT Alpine version
#   than the one used here: nothing at runtime is resolved against it.
# - LDFLAGS also includes "-Wl,--allow-multiple-definition": libidn2 (a
#   transitive static dependency of curl) bundles a gnulib replacement for
#   error(), which collides by name with Git's own error() in usage.c.
# - CURL_LIBCURL: Git's own curl-config-based detection (CURL_STATIC=
#   YesPlease) is incomplete on Alpine (missing OpenSSL, nghttp2, c-ares,
#   libpsl, brotli, zstd in the link line); pkg-config --static reads
#   curl's "Libs.private" field and reliably includes the full chain.
# - NO_GETTEXT / NO_PERL / NO_TCLTK / NO_GITWEB: aligned with what Alpine's
#   own git package doesn't bundle either.
# - NO_RUST=1: Git's default flipped between 2.54.0 (`ifndef WITH_RUST` --
#   Rust subsystems opt-in) and 2.55.0 (`ifdef NO_RUST` -- Rust subsystems
#   opt-OUT), so as of 2.55.0 a default build tries to `cargo build` a
#   `libgitcore.a`, failing with "cargo: not found" since this image has
#   no Rust toolchain. Explicitly opting back out avoids needing to add
#   and statically link a whole second language toolchain for a feature
#   this project doesn't need.
RUN CURL_LIBCURL="$(pkg-config --static --libs libcurl)" \
    && echo "Resolved static curl libs: ${CURL_LIBCURL}" \
    && make configure \
    && ./configure --prefix=/usr \
    && make -j"$(nproc)" \
        LDFLAGS="-static -Wl,--allow-multiple-definition" \
        CURL_LIBCURL="${CURL_LIBCURL}" \
        CSPRNG_METHOD= \
        NO_GETTEXT=1 \
        NO_PERL=1 \
        NO_TCLTK=1 \
        NO_GITWEB=1 \
        NO_RUST=1 \
        DESTDIR=/build \
        install

# Sanity check: confirm the /dev/urandom fallback path was actually compiled
# in, instead of a direct getrandom(2)/getentropy() call. The fallback path
# needs the literal string "/dev/urandom" embedded in the binary (as the
# path passed to open()); this is a much more reliable check than
# inspecting build variables, since it looks at what actually ended up in
# the compiled binary.
RUN if strings /build/usr/bin/git | grep -q "^/dev/urandom$"; then \
        echo "OK: /dev/urandom fallback found in the compiled binary"; \
    else \
        echo "ERROR: /dev/urandom string not found -- getrandom() may still be in use!" && exit 1; \
    fi

# Sanity check: verify the binary works AND is actually static. `file` may
# report "static-pie linked" instead of "statically linked" -- this is
# still a fully static, self-contained binary, just built as a
# position-independent executable. Both forms are accepted here.
RUN /build/usr/bin/git --version \
    && (file /build/usr/bin/git | grep -qE "statically linked|static-pie linked" \
        && echo "OK: static binary confirmed" \
        || (echo "ERROR: the binary does not appear to be static!" && file /build/usr/bin/git && exit 1))

# ==============================================================================
# Final artifact: just the compiled files, nothing else. Consumers pull this
# image and COPY --from= it (via docker buildx) rather than running it
# directly -- there is no shell, no libc, nothing but the static binaries.
# ==============================================================================
FROM scratch

ARG GIT_VERSION
LABEL org.opencontainers.image.title="git-urandom-compat"
LABEL org.opencontainers.image.description="Statically-linked Git ${GIT_VERSION}, patched to use /dev/urandom instead of getrandom(2), for Linux kernels older than 3.17"
LABEL org.opencontainers.image.source="https://github.com/mbarbeaux/git-urandom-compat"
LABEL org.opencontainers.image.licenses="MIT"

COPY --from=builder /build/usr/bin/git* /bin/
COPY --from=builder /build/usr/libexec/git-core/ /libexec/git-core/
COPY --from=builder /build/usr/share/git-core/ /share/git-core/
