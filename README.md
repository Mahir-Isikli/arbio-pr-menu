# Arbio PR Menu

A small native macOS menu bar app for checking GitHub pull request status.

It uses your existing GitHub CLI login, so it does not store GitHub tokens. New installs are read-only by default. Write actions, such as rebase, ready/draft changes, and squash merge, must be enabled explicitly in the app and are limited to your own PRs.

## Download and run

1. Download `ArbioPRMenu.app.zip` from the latest GitHub Release.
2. Unzip it and move `ArbioPRMenu.app` to `/Applications` or `~/Applications`.
3. Make sure GitHub CLI is installed and authenticated:

```bash
brew install gh
gh auth login
gh auth status
```

4. If macOS blocks the app because the pilot build is not notarized, run:

```bash
xattr -dr com.apple.quarantine /Applications/ArbioPRMenu.app
open /Applications/ArbioPRMenu.app
```

If you installed it in your user Applications folder instead:

```bash
xattr -dr com.apple.quarantine ~/Applications/ArbioPRMenu.app
open ~/Applications/ArbioPRMenu.app
```

The app appears in the macOS menu bar and has no Dock icon.

## Configure the repository

The default repository is `arbiogroup/arbio-platform`.

To use another repository:

```bash
defaults write com.arbio.pr-menu ArbioPRMenu.repositorySlug owner/repo
```

Reset to the default:

```bash
defaults delete com.arbio.pr-menu ArbioPRMenu.repositorySlug
```

## Build from source

You do not need Xcode to run a release build. To build from source, install Xcode Command Line Tools or Xcode, then run:

```bash
./scripts/build-app.sh
```

The app bundle is written to:

```text
dist/ArbioPRMenu.app
```

Create a release zip:

```bash
cd dist
zip -r ArbioPRMenu.app.zip ArbioPRMenu.app
```

## Troubleshooting

If PRs do not load, check GitHub CLI access:

```bash
gh auth status
gh pr list --repo arbiogroup/arbio-platform --author @me --state open
```

If your organization requires SSO, authorize the GitHub CLI token for the organization in GitHub settings.
