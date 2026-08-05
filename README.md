# git-urandom-compat

[![Build and publish static Git](https://github.com/mbarbeaux/git-urandom-compat/actions/workflows/docker-build.yml/badge.svg?branch=main)](https://github.com/mbarbeaux/git-urandom-compat/actions/workflows/docker-build.yml)

## Statically-linked Git, patched for pre-3.17 Linux kernels

This repository compiles [Git](https://git-scm.com/) from source, patched to
fall back to `/dev/urandom` instead of calling the `getrandom(2)` syscall
directly, and links it **statically** so the result runs unmodified on any
Linux distribution or kernel version. One image is published per upstream
Git release (e.g. `2.52.0`), for `amd64`, `arm64`, `arm/v6` and `riscv64`.

It exists to be **consumed** by
[forgejo-urandom-compat](https://github.com/mbarbeaux/forgejo-urandom-compat)
and [gitea-urandom-compat](https://github.com/mbarbeaux/gitea-urandom-compat)
via `COPY --from=`, instead of each of them recompiling the same Git source
independently. In practice, many consecutive Forgejo/Gitea releases bundle
the exact same Git version — recompiling it for every single one of them was
pure waste; this repository is where that compile work happens exactly once
per Git version, across every architecture either project needs.

## The problem being solved

Since Git 2.36, temporary filename generation uses the Linux `getrandom(2)`
syscall — available only since kernel 3.17 — **with no fallback** to the
older `/dev/urandom` method if compiled with `HAVE_GETRANDOM` (the default on
Linux). This breaks Git on older kernels — kernels that many Synology NAS
devices still run today, including on recently sold models, even under
recent DSM versions.

## Usage

Pull an exact Git release, or `latest` for the newest one built:

```bash
docker pull ghcr.io/mbarbeaux/git-urandom-compat:2.52.0
```

The image contains **only** the compiled files (`FROM scratch` — no shell,
no libc, nothing else), meant to be copied from in a downstream `Dockerfile`:

```dockerfile
FROM your-base-image AS final
COPY --from=ghcr.io/mbarbeaux/git-urandom-compat:2.52.0 /bin/git* /usr/bin/
COPY --from=ghcr.io/mbarbeaux/git-urandom-compat:2.52.0 /libexec/git-core/ /usr/libexec/git-core/
COPY --from=ghcr.io/mbarbeaux/git-urandom-compat:2.52.0 /share/git-core/ /usr/share/git-core/
```

The binary has no runtime dependency on the base image's shared libraries
(verified at build time — see [How it works](#how-it-works)), so it's safe
to copy into a base image running a different Alpine (or other distro)
version than the one this image was built with.

You can also build a given version yourself locally, via the `GIT_VERSION`
build argument (required, no default):

```bash
docker build -t git-urandom-compat --build-arg GIT_VERSION=2.52.0 .
```

## How it works

The `Dockerfile`:

1. Starts from a plain `alpine:latest` (this image has no dependency on any
   specific Forgejo/Gitea base — it exists independently of them).
2. Downloads the Git source for the exact requested `GIT_VERSION` from
   GitHub.
3. Recompiles it with `CSPRNG_METHOD=` (empty), to force the fallback to
   `/dev/urandom` instead of `getrandom()`.
4. Links the result statically (`LDFLAGS="-static"`), for a fully
   self-contained binary, with no dependency on `musl`/`libcurl`/etc.
5. Automatically verifies, via two checks, that the resulting binary is
   indeed static **and** does use `/dev/urandom` (the build explicitly
   fails otherwise).
6. Copies just the compiled files into a `FROM scratch` final image — no
   shell, no package manager, nothing beyond the binaries themselves.

See the comments in the `Dockerfile` for the details of each technical
choice (library link order, symbol conflict with `libidn2`, etc.) — see
also `CLAUDE.md` for the full history and root-cause analysis.

## Pre-built images (GitHub Actions CI)

This repository includes a GitHub Actions workflow
(`.github/workflows/docker-build.yml`) that automatically builds and
publishes an image to **GitHub Container Registry** for every non-RC Git
release (tags matching `vX.Y.Z`, excluding `-rcN` pre-releases) that is
`>= MIN_GIT_VERSION` (currently `2.50.0`). The bug this repository patches
around was introduced in Git 2.36, but building every release since then
(~80 versions) would be pure waste: `forgejo-urandom-compat` and
`gitea-urandom-compat` only ever request whichever Git version is actually
bundled in the Forgejo/Gitea release they're building, and neither project
moves that version backwards over time. `2.50.0` is a floor with a small
buffer below what's actually in use today (Forgejo 15.x / Gitea 1.26.x ->
Git 2.52.0, Gitea 1.27.x -> Git 2.54.0).

A release is **built once and never rebuilt**: Git's own release tags are
immutable, so once `2.52.0` is published here, there's no drift to detect or
recover from (unlike Forgejo/Gitea's own floating base-image tags, this
repository has no digest-drift-detection mechanism — it doesn't need one).

It triggers:

- on every push to `main` that modifies the `Dockerfile` (or the workflow
  itself);
- daily (02:00 UTC — ahead of forgejo/gitea-urandom-compat's own 03:00 UTC
  schedule, so a newly-released Git version is normally already published
  here by the time those repos look for it), to detect and build any new
  Git release;
- manually, via the repository's *Actions* tab (`workflow_dispatch`), with
  an optional `git_version` input to force a rebuild of one exact release
  even if already published.

**Making the package public**: the first time the workflow pushes an image,
the resulting GHCR package is **private by default**, even though the
repository is public — it must be switched to *Public* once, manually, in
the package's settings page, otherwise `docker pull` will require
authentication.

## Maintenance

- **New Git releases**: nothing to do — the daily schedule discovers and
  builds them automatically.
- **Verifying after a build**: the build deliberately fails (`exit 1`) if
  the compiled binary doesn't use `/dev/urandom`, or isn't actually static
  — so a `docker build` that finishes without error is itself a guarantee
  that the fix is active and the binary is portable.
- **Architecture support**: the platform list
  (`amd64,arm64,arm/v6,riscv64`) is the union of what
  forgejo-urandom-compat and gitea-urandom-compat each need. If either
  project's own supported architectures change, this list should be
  revisited.

## Origin

This repository was split out of
[forgejo-urandom-compat](https://github.com/mbarbeaux/forgejo-urandom-compat)
after noticing that every Forgejo release it rebuilt for embedded the exact
same Git version — recompiling Git once per Forgejo/Gitea release was pure
redundant CI time. It was put together with the assistance of Claude
(Anthropic).

## License

This project is licensed under the [MIT License](LICENSE).
