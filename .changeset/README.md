# Changesets

Run `pnpm changeset` to describe a change and pick its version bump:

- `major`: breaking change to the public Swift API or behavior.
- `minor`: new feature, backward compatible.
- `patch`: bug fix, backward compatible.

Commit the generated file with your PR; CI fails on PRs without one. For a PR that needs no release (docs, CI, tests), run `pnpm changeset --empty`.

On merge to `main`, the release workflow opens a "Version Packages" PR that bumps `package.json` (and `LicenseManager.sdkVersion`) to the highest bump among pending changesets and writes `CHANGELOG.md`. It merges that PR, tags `X.Y.Z` and creates a GitHub Release with that version's changelog. SwiftPM and the Swift Package Index pick up the tag.
