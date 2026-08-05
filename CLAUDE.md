# CLAUDE.md

Context for Claude (or any future revival of this repository).

## What this repository does

A `Dockerfile` that compiles [Git](https://git-scm.com/) from source,
patched to fall back to `/dev/urandom` instead of calling the
`getrandom(2)` syscall directly, and statically links the result so it
runs on any Linux kernel, including ones older than 3.17. One image is
published per upstream Git release, for every architecture needed by its
two consumers.

This repository exists purely to be **depended on**: it has no
Forgejo/Gitea-specific logic at all. `forgejo-urandom-compat` and
`gitea-urandom-compat` each rebuild their respective official rootless
image with Alpine's `git` package replaced by a binary pulled from here
(`COPY --from=ghcr.io/mbarbeaux/git-urandom-compat:<version>`), instead of
recompiling Git themselves.

## Why this repository exists (origin)

Split out of `forgejo-urandom-compat` after inspecting the Git version
embedded in every Forgejo rootless release from `15.0.0` through
`16.0.2` (10 releases): **all 10 embedded the exact identical Git version,
2.52.0** (only the underlying Alpine point-release differed: 3.23.4 vs
3.23.5). `forgejo-urandom-compat`'s original design recompiled Git from
source independently for every single Forgejo release it built — meaning
those 10 CI runs compiled the literally same Git source 10 times, each
taking roughly an hour due to QEMU cross-compilation for arm64/arm/v6.
Given Git releases far less often than Forgejo/Gitea do, decoupling "build
Git" from "assemble the Forgejo/Gitea image" turns that redundant
compilation into a one-time cost paid here, instead of being paid again by
every downstream release that happens to bundle the same Git version.

## The original problem (symptom, root cause)

Same underlying bug as documented in detail in
`forgejo-urandom-compat/CLAUDE.md` — summarized here:

1. Since **Git 2.36**, Git calls `csprng_bytes()` (in `wrapper.c`) to
   generate temporary filenames cryptographically. On Linux, if compiled
   with `HAVE_GETRANDOM` (the default), this calls **`getrandom(2)`**
   directly — available only since kernel **3.17** — **with no fallback**
   to `/dev/urandom` if the call fails.
2. Git's `config.mak.uname` **automatically forces**
   `CSPRNG_METHOD = getrandom` for any system detected as `Linux`,
   regardless of whether the variable is set elsewhere — it must be
   explicitly overridden via the `make` command line (`CSPRNG_METHOD=`
   empty), which takes priority over any in-Makefile assignment.
3. Alpine Linux's precompiled `git` packages inherit this default
   behavior, which is why every Forgejo/Gitea image (both based on
   Alpine) breaks on kernels older than 3.17 (e.g. Synology NAS devices
   still on kernel 3.10, even under recent DSM).

## The build recipe

Identical compile options to `forgejo-urandom-compat`'s original
`git-builder` stage, just decoupled from any specific Forgejo/Gitea base
image (`FROM alpine:latest` instead of `FROM forgejo-original`):

```
make -j"$(nproc)" \
    LDFLAGS="-static -Wl,--allow-multiple-definition" \
    CURL_LIBCURL="$(pkg-config --static --libs libcurl)" \
    CSPRNG_METHOD= \
    NO_GETTEXT=1 NO_PERL=1 NO_TCLTK=1 NO_GITWEB=1 \
    DESTDIR=/build install
```

See the comments in the `Dockerfile` for why each flag is needed
(`CSPRNG_METHOD=` is the actual fix; `-static` is the point of this whole
repository; `-Wl,--allow-multiple-definition` works around a symbol clash
between Git's own `error()` and a `gnulib` replacement bundled by
`libidn2`; `CURL_LIBCURL` bypasses Git's own incomplete
`curl-config --static-libs` detection on Alpine).

Two build-time checks fail the build (`exit 1`) if not satisfied — a
successful build is itself proof the fix is active:

1. `strings /build/usr/bin/git | grep "^/dev/urandom$"` — confirms the
   `/dev/urandom` fallback branch was compiled in, not `getrandom()`.
2. `file /build/usr/bin/git | grep -qE "statically linked|static-pie
   linked"` — confirms the binary has no shared library dependencies.

## Why static linking makes this safe to decouple

The whole point of `-static` is that the resulting binary has **zero
runtime dependency** on the environment it was compiled in. This was
verified concretely before building this repository: pulled and ran
`git --version` inside 10 different `forgejo/forgejo` rootless images
(15.0.0 through 16.0.2, spanning Alpine 3.23.4 and 3.23.5) and confirmed
identical Git version and working binaries throughout. It was verified
again after writing this repository's `Dockerfile`: a binary compiled
here against `alpine:latest` was copied (`COPY --from=`) into a plain
`alpine:latest` container and successfully ran `git init` / `git commit`
without any shared-library or runtime errors. This is what makes it safe
for `forgejo-urandom-compat` (built against whatever Alpine version the
current `forgejo-original` image happens to use) to consume a Git binary
built here against a possibly-different Alpine version.

## Artifact format

The final image is `FROM scratch` — no shell, no libc, nothing but the
compiled files, at these paths:

- `/bin/git*` (the `git` binary plus any `git-*` hardlinks/symlinks Git's
  own `make install` creates)
- `/libexec/git-core/`
- `/share/git-core/`

Consumers `COPY --from=ghcr.io/mbarbeaux/git-urandom-compat:<version>` these
into their own image at the equivalent `/usr/...` paths. Tags are the exact
Git version with **no `v` prefix** (e.g. `2.52.0`, not `v2.52.0`) —
deliberately chosen to match `git --version`'s own output verbatim
(`git version 2.52.0`), so a consumer that already parses that string to
determine which Git version its base image bundles can use the result
directly as this repository's tag, with no transformation.

## CI/CD (GitHub Actions)

`.github/workflows/docker-build.yml` has two jobs, structurally the same
pattern as `forgejo-urandom-compat`'s (see that repo's CLAUDE.md for the
fuller rationale behind this shape), but simpler since there is no
digest-drift detection here (Git's release tags are immutable; nothing to
compare against):

1. `discover`: lists every `git/git` tag via `git ls-remote --tags --refs
   https://github.com/git/git.git` (NOT the GitHub REST API — avoids
   pagination and the unauthenticated 60/hr rate limit entirely; git/git
   has 1000+ tags across its full history). Filters to `vX.Y.Z` exactly
   (excludes `-rcN` pre-releases and older `vX.Y.Z.W`-style tags),
   strips the `v` prefix, keeps only `>= MIN_GIT_VERSION` (currently
   `2.50.0` — NOT the version that introduced the bug (2.36), but a floor
   just below what Forgejo/Gitea's currently-tracked oldest releases
   actually bundle; see the "MIN_GIT_VERSION" point of attention below for
   the full reasoning). Diffs that list against this repository's own
   already-published `ghcr.io` tags (read-only `skopeo login` +
   `list-tags`, same pattern as `forgejo-urandom-compat`) to compute the
   build matrix (`versions` output) — an already-built release is simply
   never rebuilt. `latest` is computed from the FULL upstream list
   regardless of what's built this run, same rationale as
   `forgejo-urandom-compat`.
2. `build`: matrix job (one job per missing release, `max-parallel: 4` to
   avoid tripping GitHub's secondary API rate limit on concurrent
   `ghcr.io` pushes -- this bit `forgejo-urandom-compat` on its first
   large catch-up run), builds for `linux/amd64,linux/arm64,linux/arm/v6,
   linux/riscv64` (the UNION of what `forgejo-urandom-compat`
   needs -- amd64/arm64/arm-v6 -- and what `gitea-urandom-compat` needs --
   amd64/arm64/riscv64, discovered by inspecting each project's own
   published rootless image via `docker buildx imagetools inspect`), and
   pushes to `ghcr.io`, tagged with the exact version and, for whichever
   release is the overall `latest`, also `latest`.

Triggers: push to `main` touching the `Dockerfile` or the workflow
itself, a daily schedule (02:00 UTC -- ONE HOUR ahead of
`forgejo-urandom-compat`/`gitea-urandom-compat`'s own 03:00 UTC schedule,
so a brand new Git release is normally already published here by the
time those repos' daily runs look for it), and manual `workflow_dispatch`
(with an optional `git_version` input to force a rebuild of one exact
release even if already published).

**Deliberate design choice**: if a consumer repo ever needs a Git version
that hasn't been built here yet (e.g. this repo's daily cron hasn't caught
up to a very recent release), the consumer's build simply fails and waits
for the next day's cron here to catch up -- no cross-repo triggering, no
shared secrets/PAT between repositories, no added latency-hiding
complexity. This was a deliberate tradeoff in favor of simplicity over
tightening that (already narrow, since Git releases far less often than
this repo's cron runs) gap.

Important operational note: the GHCR package created by the workflow is
**private by default** on first push, even though the repository is
public -- it must be switched to "Public" once, manually, in the
package's settings page, otherwise `docker pull` will require
authentication.

## Points of attention for a future revival

- The FIRST run after this repository's creation has 9 Git releases to
  build (`>= 2.50.0`, non-RC: 2.50.0, 2.50.1, 2.51.0-2, 2.52.0, 2.53.0,
  2.54.0, 2.55.0). This was deliberately kept small by setting
  `MIN_GIT_VERSION` to 2.50.0 rather than 2.36 (when the bug was
  introduced) -- building the full ~80-release range back to 2.36 was
  considered and rejected as pure waste, since neither consumer repo will
  ever request a Git version older than what its own currently-tracked
  oldest release already bundles (2.52.0, as of this writing), and that
  floor only moves forward over time.
- `riscv64` is a newer, less common Alpine target. Package availability
  for all the `-static` variants this build needs was verified manually
  before writing this Dockerfile, and a full end-to-end build (compile +
  both verification checks + scratch-stage export) was tested locally
  before ever running in CI. If a future Alpine release drops or renames
  a `-static` package for `riscv64` specifically (while keeping it for
  other architectures), the `riscv64` leg of a multi-platform
  `docker buildx build` fails and
  takes the WHOLE multi-arch push down with it (buildx pushes one atomic
  manifest list per release) -- diagnose via `cannot find -lXXX` in that
  platform's build log specifically.
  For a full explanation of each `-static` package, see the Dockerfile
  comments and `forgejo-urandom-compat/CLAUDE.md`.
- If `forgejo-urandom-compat` or `gitea-urandom-compat` ever add/drop a
  supported architecture, the `platforms:` list in this repo's workflow
  needs to be revisited (it's a manually-maintained union, not derived
  automatically).
- If Git ever changes its release tag naming scheme (currently
  `vX.Y.Z`, e.g. `v2.52.0`), the `discover` job's regex needs updating.
- `MIN_GIT_VERSION` (currently `2.50.0`) is a workflow-level env var in
  `docker-build.yml`, deliberately set to track consumer-side need rather
  than the bug's origin (Git 2.36) -- see the point above. Bump it forward
  if Forgejo/Gitea's own MIN_MAJOR_VERSION floors ever advance far enough
  that the oldest Git version either project still needs moves past it
  too -- there's no need to ever move it backward on its own, since an
  excluded older release will never be requested again by either
  existing consumer. If a third consumer repo is ever added and needs an
  older Git version than what's currently published here, lower it and
  let `discover` backfill the gap on its next run.

## License

This project is licensed under the [MIT License](LICENSE).
