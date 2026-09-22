# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-09-22

### Added

- `RubyLLM::Modes::Mode` with `mode_description` and `mode_name`, and
  `RubyLLM::ModeAgent`, an Agent with Mode extended.
- `RubyLLM::Modes::Router` with the declaration DSL (`inputs`, `mode`,
  `guidance`, `prompt`, `history`, `fallback`, `classify`, `on_error`),
  inheritance that copies declarations, validation in `new`, availability
  via `if:`, history normalisation, `call`, `explicit`, and the ordered
  outcome table.
- `Decision` and `Route` value objects; `Route#to_h` for logs.
- The `:chat` classifier backend with the built-in routing frame, the
  selection schema, `prompt` overrides (template name or block), and
  `chat_factory:`.
- `DeclarationError`, `UnknownMode` (a `KeyError`), and `ContractError`.
- Three acceptance examples under `examples/`, run as integration tests.

### Not included

- The `:judge` backend. `classify with: :judge` raises `DeclarationError`
  until `RubyLLM::Judge` ships in a released RubyLLM.
