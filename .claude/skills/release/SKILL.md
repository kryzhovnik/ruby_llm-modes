---
name: release
description: Release this gem to rubygems.org and GitHub. Argument is patch, minor, major, or an explicit X.Y.Z.
disable-model-invocation: true
argument-hint: "patch | minor | major | X.Y.Z"
---

Cut a release of ruby_llm-modes: `$ARGUMENTS` names the bump. Every step
is a gate: stop at the first failure, report what failed, and leave the
repository as it was. The steps before the commit change nothing that
cannot be undone with `git checkout`.

## 1. Preconditions

All of these hold, or stop:

- Branch is `main`, the working tree is clean, and `main` is not behind
  `origin/main` (`git fetch` first).
- `gh auth status` succeeds and `~/.local/share/gem/credentials` exists.
- `## [Unreleased]` in `CHANGELOG.md` has at least one entry.

## 2. Pick the version

Current version is `VERSION` in `lib/ruby_llm/modes/version.rb`.
Resolve `$ARGUMENTS` to the new number: `patch`, `minor`, `major`, or an
explicit `X.Y.Z` greater than the current one.

Cross-check the bump against the `Unreleased` headings and raise it with
the user instead of deciding alone when they disagree:

- `Added` or `Removed` under a `patch` bump.
- Only `Changed` or `Fixed` under a `minor` bump.
- A documented breaking change under anything but `major` (0.x: `minor`).

When `Added` names a public API, confirm README mentions it; a missing
mention is a stop, since the README ships inside the gem.

## 3. Prepare the tree

- `CHANGELOG.md`: rename `## [Unreleased]` to `## [X.Y.Z] - <today>` and
  insert an empty `## [Unreleased]` above it.
- `lib/ruby_llm/modes/version.rb`: set `VERSION`.
- `bundle install`, so the ignored `Gemfile.lock` carries the new version.

## 4. Verify

- `bundle exec rake test` and `bundle exec rubocop` pass.
- `gem build ruby_llm-modes.gemspec -o /tmp/release-check.gem` and list
  its contents with `tar -xOf /tmp/release-check.gem data.tar.gz | tar -tz`.
  The listing is only `lib/`, `assets/`, `README.md`, `CHANGELOG.md`,
  `LICENSE*`, and the gemspec. Anything else (`.scratch/`, `SPEC.md`,
  `test/`) is a stop. Delete the check gem afterwards.

## 5. Commit

One commit, message `Release X.Y.Z`, body a short plain-English summary of
the changelog section. No attribution trailers (see AGENTS.md).

## 6. Publish

`bundle exec rake release` builds the gem, tags `vX.Y.Z`, pushes the
commit and the tag, and pushes the gem. Read its output: all four lines
are present or the release is incomplete.

If it fails after `Tagged vX.Y.Z.` and before `Pushed ruby_llm-modes`,
report which of these the user has to run, never run them unasked:

```sh
git tag -d vX.Y.Z
git push origin :refs/tags/vX.Y.Z   # only if the tag was pushed
```

## 7. GitHub Release

Notes are the `[X.Y.Z]` section of `CHANGELOG.md` without its heading:

```sh
awk '/^## \[X.Y.Z\]/{f=1; next} /^## \[/{f=0} f' CHANGELOG.md \
  | awk 'NF || started {started=1; print}' > "$NOTES"
gh release create vX.Y.Z --title "X.Y.Z" --notes-file "$NOTES" --verify-tag
```

## 8. Confirm

All three, or report which is missing:

- `curl -s https://rubygems.org/api/v1/versions/ruby_llm-modes/latest.json`
  returns `X.Y.Z`. The index lags by a minute or two; retry before
  calling it a failure.
- `git ls-remote --tags origin` lists `vX.Y.Z`.
- `gh release view vX.Y.Z` succeeds.

Report the gem page, the release URL, and the changelog section.
