# Coding standards

Use [RubyLLM's conventions](https://github.com/crmne/ruby_llm/blob/main/AGENTS.md)
as a design reference. The rules below are the local standard.

- Follow RubyLLM::Agent naming and conventions where the APIs overlap. Use one
  name per concept, keyword arguments, readers, and predicates ending in `?`.
- Router owns mode selection. Backend details belong in Classifiers. Keep
  provider-specific behavior out of the router.
- Use explicit result objects such as Decision, Route, and Registration.
  Use hashes at boundaries and for serialization. Library-defined enumerations
  use symbols; external identifiers remain strings. Preserve documented wire
  formats in `to_h`.
- Keep the library usable without Rails. Integrate through the shared RubyLLM
  API rather than direct dependencies on Rails or concrete providers.
- Test public behavior with Minitest. Add a regression test for bug fixes.
  Keep routine tests offline by substituting external calls.
- Document public contracts and constraints that are not clear from the code.
  Avoid comments that restate the implementation.
- Keep changes focused. Update README examples and reference text with public
  API changes. Avoid unrelated refactoring and formatting changes.
- Follow the existing RuboCop Omakase configuration. Do not copy upstream
  tooling or add architectural checks without a concrete need.

## Checks

```sh
bundle exec rake test
bundle exec rubocop
```

## Commits

Write plain English commit messages that describe the change. Do not add AI
attribution or co-author trailers for coding agents.
