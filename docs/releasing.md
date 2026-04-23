# Releasing Glorbo

End-to-end recipe for cutting a new pre-1.0 release and propagating
it to the Homebrew tap.

## Scope

Pre-1.0 Glorbo releases publish Linux binaries (x86_64 + aarch64)
via a signed GitHub Release, and the `foobarto/homebrew-tap` tap
serves `brew install foobarto/tap/glorbo` on those machines.

macOS binaries are declared in `mix.exs` Burrito targets but the
GHA `build-macos` matrix is currently disabled (queue-indefinitely
issue, see `.github/workflows/ci.yml` comment); until that flag is
flipped, macOS users build from source.

## The short version

```bash
# 1. Bump version (mix.exs + CHANGELOG [Unreleased] → versioned heading)
$EDITOR mix.exs CHANGELOG.md

# 2. Local gate
mix precommit
mix gep.validate
mix glorbo.docs.file_formats --check

# 3. Commit + tag + push
git commit -am "chore(release): cut vX.Y.Z"
git tag -a vX.Y.Z -m "vX.Y.Z"
git push origin main
git push origin vX.Y.Z

# 4. Wait for CI. The `publish` job runs on tag push, builds +
#    signs + uploads Burrito binaries, then creates the GitHub
#    Release with attached `SHA256SUMS` + cosign signatures.
gh run watch

# 5. Sanity-check the release surface
gh release view vX.Y.Z --json assets --jq '.assets[].name'

# 6. Refresh the Homebrew tap formula
git clone git@github.com:foobarto/homebrew-tap.git ../homebrew-tap
mix glorbo.release_formula --write --tap-path ../homebrew-tap
(cd ../homebrew-tap && git commit -am "glorbo vX.Y.Z" && git push)

# 7. Smoke-test the tap
brew tap foobarto/tap
brew update
brew upgrade glorbo       # or: brew install if not yet installed
glorbo doctor
```

## The long version

### 1. Version bump

`mix.exs` `version:` is the source of truth. Matching entries:

  * `CHANGELOG.md` — promote the `[Unreleased]` heading to
    `[X.Y.Z] — YYYY-MM-DD` and add a fresh empty `[Unreleased]`.
  * `README.md` — update the "Latest release" bullet in the
    Project Status section.

### 2. Local gate

Run everything CI runs, locally. Precommit aggregates all of it,
but for explicit confirmation:

```bash
mix format --check-formatted
mix compile --warnings-as-errors
mix credo --strict
mix test
mix gep.validate
mix glorbo.docs.file_formats --check
```

**Gotcha:** `mix credo --strict` doesn't exit non-zero on refactor
warnings (exit code 8). CI does. Read the output carefully — don't
rely on `echo $?` alone.

### 3. Tag + push

Annotated tags only. The signed-release CI pipeline triggers on
`refs/tags/v*`, so the tag name MUST start with `v`.

```bash
git tag -a vX.Y.Z -m "vX.Y.Z"
git push origin vX.Y.Z
```

### 4. Wait for CI

The `publish` job in `.github/workflows/ci.yml`:

  1. Runs `build-and-test` on both Linux arches.
  2. Builds Burrito releases for `glorbo-linux-x86_64` and
     `glorbo-linux-aarch64`.
  3. Signs each binary with cosign using the GHA OIDC token.
  4. Generates `SHA256SUMS` (two-column sha+filename).
  5. Uploads all artifacts + creates the GitHub Release with the
     `CHANGELOG.md` section as the body.

`build-macos` is disabled (`if: false`); until it's re-enabled the
release is Linux-only. The release-bundling step in `ci.yml`
documents which lines to restore when flipping the flag.

If the release job fails, fix the cause, re-tag (`git tag -d
vX.Y.Z && git push origin :refs/tags/vX.Y.Z && git tag -a vX.Y.Z
-m "vX.Y.Z" && git push origin vX.Y.Z`), and re-run.

### 5. Sanity-check

```bash
gh release view vX.Y.Z --json assets --jq '.assets[].name'
```

Should list at least:

  * `glorbo-linux-x86_64` + `.sig` + `.pub`
  * `glorbo-linux-aarch64` + `.sig` + `.pub`
  * `SHA256SUMS` + `.sig` + `.pub`

Download one binary and check `glorbo doctor` prints the expected
version.

### 6. Refresh the Homebrew tap

The formula lives at `foobarto/homebrew-tap:Formula/glorbo.rb`.

```bash
# Clone side-by-side (default `--tap-path`)
git clone git@github.com:foobarto/homebrew-tap.git ../homebrew-tap

# Regenerate against the just-published release. The task fetches
# SHA256SUMS over HTTPS and renders a Linux-only formula when the
# darwin SHAs aren't present (current state); restore the darwin
# block automatically once `build-macos` lands again.
mix glorbo.release_formula --write --tap-path ../homebrew-tap

# Verify the diff looks right — should only touch `version "..."`,
# the URL versions, and the SHA256s. No handwritten edits to the
# formula (it's generated; hand edits get clobbered on next
# release).
(cd ../homebrew-tap && git diff Formula/glorbo.rb)

# Ship it
(cd ../homebrew-tap && git commit -am "glorbo vX.Y.Z" && git push)
```

### 7. Smoke-test

On a fresh Linux host (or `brew upgrade`-able on an existing one):

```bash
brew tap foobarto/tap
brew update
brew install glorbo   # or: brew upgrade glorbo
glorbo doctor
```

`brew audit --new foobarto/tap/glorbo` shouldn't complain (it's a
pre-existing formula, not a new submission, so the audit rules are
lenient).

## Task reference

### `mix glorbo.release_formula`

```bash
mix glorbo.release_formula                          # stdout
mix glorbo.release_formula --write                  # ../homebrew-tap/Formula/glorbo.rb
mix glorbo.release_formula --write --tap-path PATH  # elsewhere
mix glorbo.release_formula --version X.Y.Z          # any prior version (smoke-test)
```

All runs require internet (fetches
`https://github.com/foobarto/glorbo/releases/download/vX.Y.Z/SHA256SUMS`);
the task fails loudly if the release isn't published or the asset
list is incomplete.

## Known gaps

- **No CI automation pushes the tap yet.** Manual steps 6+7 above
  are the handoff. A future CI job could do this with a deploy
  key + `gh api` push — tracked as a nice-to-have.
- **build-macos disabled.** See `.github/workflows/ci.yml`
  comments. Restore the `if: false` gate + the release-bundling
  lines once GHA macOS runners have capacity.
- **No rollback story.** If a release is bad, push a patch
  (`vX.Y.Z+1`) rather than trying to yank — `brew upgrade` picks
  up the newer one and old clients pin to whatever they installed.
