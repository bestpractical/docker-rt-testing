# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A single `Dockerfile` that builds a base Docker image for **testing** Request Tracker (RT)
and its Perl dependencies. The image deliberately installs a "maximal" set of dependencies
(all databases, dev features, most optional features) so RT's full test suite can run against
it, and so the compiled dependency stack can be redeployed to same-distro/arch hosts without
rebuilding. It is not meant for slim production use.

There is no application code here — the deliverable is the image. `README` is the canonical
source for build arguments and usage; read it before changing build behavior.

## How the image is consumed (the full pipeline)

1. Build the image from this `Dockerfile` (below) and **push it to Docker Hub** under
   `bpssysadmin/rt-base-debian:<tag>`.
2. The **RT repository** pulls it in: RT's own `Dockerfile` (a testing-only Dockerfile at the
   root of the RT source tree) starts with
   `FROM bpssysadmin/rt-base-debian:<tag>` — pinned to a specific tag — adds test env vars and
   the `rt-user`, then RT's **GitHub Actions** (`.github/workflows/test-all.yml`,
   `test-oracle.yml`) build RT on top of it and run the suite across SQLite / MariaDB /
   Postgres / Oracle and various server configs.

So a new base image only takes effect once someone bumps the pinned `FROM` tag in the RT
repo's `Dockerfile`. Building/pushing here is not enough on its own.

### Two policies that shape changes here

- **Forward-only:** we only move forward in time. When we adopt a newer Debian version we do
  **not** go back and update older-version branches. Old distro branches are frozen.
- **One image serves both RT 5 and RT 6:** the same base image is expected to run both the RT 5
  and RT 6 branches, and has managed to so far. When changing dependencies, keep both in mind —
  don't drop or pin something in a way that breaks the other line. (`CPANFILE` defaults to
  `6.0-trunk`, but the installed stack must still satisfy RT 5's tests.)

## Build and push

```bash
# Build (tag convention: RT-<rtversion>-<distro>-<yyyymmdd>)
docker build -t bpssysadmin/rt-base-debian:RT-6.0.0-bullseye-20260708 .

# Override the Perl version (the only arg you normally set)
docker build --build-arg PERL_VERSION=5.34.3 -t <tag> .

# Push
docker push bpssysadmin/rt-base-debian:<tag>
```

Running the image (default `CMD`) prints all installed Perl modules and versions in CPAN
autobundle format — used to diff dependency sets between builds.

### Build arguments (see README for full detail)

- `PERL_VERSION` — Perl source release to build/test/install (e.g. `5.34.3`).
- `CPANFILE` — URL of RT's `cpanfile`; controls which RT version's deps are installed.
  Change `6.0-trunk`/`stable`/etc. in the URL to target a different RT version.
- `CPM` — URL of the `cpm` installer script (rarely changed).
- `PERL_CONFIGURE` — options for Perl's `Configure` (default `-des`). Do **not** set `-Dprefix` here.
- `PERL_PREFIX` — install path (default `/opt/perl-$PERL_VERSION`, symlinked to `/opt/perl`).

## Branch model

There is no single main line of development here — **each branch targets a distro/variant**,
and that is how variants are maintained (not via build args in one branch):

- `stretch` (repo default / origin HEAD), `buster`, `bullseye` — Debian base per branch
  (`FROM debian:<distro>-slim`).
- `-oracle` variants add Oracle instantclient drivers.
- `bullseye-rt6` (current) — bullseye targeting RT 6.

When changing something distro- or version-specific, confirm which branch you're on and
whether the change belongs on other branches too. Diff branches (e.g. `git diff stretch..bullseye-rt6`)
to see how a variant diverges.

## How the Dockerfile is structured (why the ordering matters)

The steps run in a deliberate order; several carry non-obvious workarounds documented inline:

1. **System packages** — build tools, Apache/fcgid, DB client libs (mariadb, libpq via the
   PostgreSQL APT repo), browsers (chromium, firefox-esr) and driver deps.
2. **Oracle instantclient** — RPMs converted with `alien`; sets `ORACLE_HOME`/`LD_LIBRARY_PATH`.
3. **geckodriver + Node.js/Playwright** — for RT's browser/dashboard-email tests. Playwright
   browsers install under `PLAYWRIGHT_BROWSERS_PATH=/tmp/playwright`.
4. **Perl from source** — built, then `make test` run **as `nobody`** (non-root `$<`) to avoid
   Net::Ping raw-packet test assumptions; a `sed` deletes POSIX termios tests that fail under
   podman/runc. Installed to `PERL_PREFIX`, symlinked `/opt/perl`, put on `PATH`.
5. **cpm** downloaded to `/opt/perl/bin`.
6. **Individually installed modules** (`XML::Simple`, `Mail::Sendmail`, `Module::Pluggable`,
   `CSS::Inliner`, `WWW::Mechanize::Chrome`, `Playwright`) — each is a separate `RUN` because it
   needs `--no-test` or must be installed *before* the bulk step to dodge a specific test
   failure or parser-selection issue. The inline comments explain each; preserve them.
7. **Bulk RT deps** — downloads RT's `cpanfile`, uses `awk` to turn each `feature` (except
   `modperl1`) into a `--feature=` flag, and runs `cpm install --test` for the whole set.

Because Docker layer caching keys on `RUN` text and preceding layers, reordering or merging
these steps changes caching and can resurrect the test failures the current split avoids.

## Local untracked artifacts

`build_log.txt` and `cpanfile` in the working tree are local scratch outputs, not part of the
image build (the build downloads its own `cpanfile`). Leave them untracked; don't commit them.
