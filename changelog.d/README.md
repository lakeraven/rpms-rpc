# Changelog fragments

Each PR adds one file here instead of editing `CHANGELOG.md`, so merges never conflict.

- Name: `<id>.<type>.md`. `<id>` is the issue or PR number; `<type>` is one of
  `added`, `changed`, `deprecated`, `removed`, `fixed`, `security`.
- The first line is the heading, the text after `### <Type> — ` (e.g. `` `Foo.bar` returns the row (#12) ``).
- The rest of the file is the body, copied verbatim: paragraphs and bullets.
- One fragment per PR. Add a second file with another type if the PR needs one.
- Order in the release: Added, Changed, Deprecated, Removed, Fixed, Security, then by numeric id.
- Check: `bundle exec rake changelog:check` (validates every fragment, non-zero on a bad one).
- Release: `bundle exec rake changelog:assemble` inserts the fragments under `## [Unreleased]`,
  ahead of the existing sections, and deletes them. Commit the result.
- Ignored by the loader: this README, `.keep`, `.gitkeep`, `.DS_Store`. Any other file is validated.
