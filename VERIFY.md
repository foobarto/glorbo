# Verifying a Glorbo Release

Every tagged release of Glorbo is signed with [Sigstore Cosign](https://www.sigstore.dev/) using the GitHub Actions OIDC token — no long-lived maintainer keys. You can verify that a downloaded binary came from this repository's CI without trusting any keyring.

## Quick Verify

```bash
# 1. Download the binary, the checksums, and the signature bundle
VERSION=v0.0.4
ARCH=x86_64   # or aarch64
curl -LO https://github.com/foobarto/glorbo/releases/download/$VERSION/glorbo-linux-$ARCH
curl -LO https://github.com/foobarto/glorbo/releases/download/$VERSION/SHA256SUMS
curl -LO https://github.com/foobarto/glorbo/releases/download/$VERSION/SHA256SUMS.sig

# 2. Verify the signature on SHA256SUMS came from foobarto/glorbo's tagged CI run
cosign verify-blob \
  --bundle SHA256SUMS.sig \
  --certificate-identity-regexp '^https://github.com/foobarto/glorbo/\.github/workflows/.+@refs/tags/v.+$' \
  --certificate-oidc-issuer 'https://token.actions.githubusercontent.com' \
  SHA256SUMS
# Expect: "Verified OK"

# 3. Verify the binary's checksum matches SHA256SUMS
sha256sum -c SHA256SUMS --ignore-missing
# Expect: "glorbo-linux-x86_64: OK"

# 4. Install
chmod +x glorbo-linux-$ARCH
mv glorbo-linux-$ARCH ~/.local/bin/glorbo
glorbo doctor
```

## Verifying a Single Binary Directly

If you only want to grab one architecture's binary, each binary also ships with its own `.sig` bundle:

```bash
curl -LO https://github.com/foobarto/glorbo/releases/download/$VERSION/glorbo-linux-$ARCH
curl -LO https://github.com/foobarto/glorbo/releases/download/$VERSION/glorbo-linux-$ARCH.sig

cosign verify-blob \
  --bundle glorbo-linux-$ARCH.sig \
  --certificate-identity-regexp '^https://github.com/foobarto/glorbo/\.github/workflows/.+@refs/tags/v.+$' \
  --certificate-oidc-issuer 'https://token.actions.githubusercontent.com' \
  glorbo-linux-$ARCH
```

## What's Being Verified

- **Identity regex** — the signature was issued by a GitHub Actions workflow file under `foobarto/glorbo`, on a tag `v*`. Pull requests cannot produce valid signatures (their identity lacks `refs/tags/v`).
- **OIDC issuer** — the signing cert was issued by GitHub's Actions OIDC provider, not a third party.
- **Transparency log** — Cosign's default behaviour verifies the signature is recorded in [Rekor](https://search.sigstore.dev/), a public append-only transparency log. Any attempt to produce a signature off-log will fail.

## Why Cosign Keyless

Glorbo does not ship with a maintainer GPG keyring. Every release signature is tied to the specific GitHub Actions run that produced it, verifiable by anyone without prior key exchange. If this repository is ever forked and its forked CI produces a release, those signatures carry the fork's identity — the regex above will reject them.

## Installing Cosign

If you don't have `cosign` installed, see the [Sigstore install guide](https://docs.sigstore.dev/cosign/system_config/installation/) or on Linux:

```bash
curl -LO https://github.com/sigstore/cosign/releases/latest/download/cosign-linux-amd64
chmod +x cosign-linux-amd64
mv cosign-linux-amd64 ~/.local/bin/cosign
```

## Reference

- Signing workflow: [`.github/workflows/ci.yml`](./.github/workflows/ci.yml) (`release` job)
- Cosign docs: https://docs.sigstore.dev/cosign/signing/overview/
- GitHub OIDC for Actions: https://docs.github.com/en/actions/deployment/security-hardening-your-deployments/about-security-hardening-with-openid-connect
