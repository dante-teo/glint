# Releasing Glint

This fork releases arm64 macOS builds from tags in `dante-teo/glint` and
publishes stable casks to `dante-teo/homebrew-tap`.

## One-time setup

### Sparkle update signing

Run this locally once:

```bash
SPARKLE_REPO=dante-teo/glint scripts/sparkle-bootstrap.sh
```

The script writes the public key to `Glint/Resources/Info.plist` and can upload
the private key to the `SPARKLE_ED_PRIV_KEY` GitHub Actions secret.

If you skipped the upload prompt, rerun the command and answer `y`.

### Homebrew tap deploy key

The release workflow needs `HOMEBREW_TAP_DEPLOY_KEY` on `dante-teo/glint`, and
the matching public key must be a writable deploy key on `dante-teo/homebrew-tap`.
The key files generated for this fork are:

```text
.secrets/homebrew-tap-deploy-key
.secrets/homebrew-tap-deploy-key.pub
```

Upload them with:

```bash
gh secret set HOMEBREW_TAP_DEPLOY_KEY \
  --repo dante-teo/glint \
  < .secrets/homebrew-tap-deploy-key

gh api repos/dante-teo/homebrew-tap/keys \
  -f title="glint release workflow" \
  -f key="$(cat .secrets/homebrew-tap-deploy-key.pub)" \
  -F read_only=false
```

### Apple Developer ID signing

Create a Developer ID Application certificate in Apple Developer with the CSR in
`.secrets/apple-developer-id.csr`. Keep `.secrets/apple-developer-id.key`
private. After downloading the certificate from Apple, import it into Keychain,
export it as a `.p12`, and set these GitHub Actions secrets on `dante-teo/glint`:

```text
APPLE_CERT_P12_BASE64
APPLE_CERT_PASSWORD
APPLE_NOTARY_ID
APPLE_NOTARY_PASSWORD
APPLE_NOTARY_TEAM_ID
```

`APPLE_NOTARY_PASSWORD` should be an app-specific password for the Apple ID.

## Cut a release

Create and push a tag:

```bash
git tag v0.1.24
git push origin v0.1.24
```

Prerelease tags such as `v0.1.24-beta.1` publish a GitHub prerelease and Sparkle
beta appcast item, but do not update the Homebrew cask.
