# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `RubyLLM::Modes::Mode` with `description` and `mode_name`, and
  `RubyLLM::ModeAgent`, an Agent with Mode extended. A mode that declares
  no `description` reads `app/prompts/<agent path>/description.txt.erb`,
  following Agent's convention for `instructions`.
- `Mode#instructions` defaults to `append: true, persist: false`, for the
  conventional `instructions.txt.erb` template as well: a mode's prompt
  follows the chat's own and stays out of a Rails record's history, so the
  call site is `route.mode(chat:).complete`.
- `RubyLLM::Modes::Router` with the declaration DSL (`inputs`, `mode`,
  `instructions`, `history`, `fallback`, `classify_with`, `on_error`),
  inheritance that copies declarations, validation in `new`, availability
  via `if:`, history normalisation with `history last: n` / `history :all`,
  `call`, `force`, and the ordered outcome table.
- `Registration` value objects: what `Router#modes` returns and what a
  classifier receives as `modes:`.
- `Decision` and `Route` value objects; `Route#decided_by` (`"caller"`,
  `"classifier"`, `"fallback"`), `Route#duration_ms`, and `to_h` on both with
  the field names as string keys, for logs.
- `Route#mode(chat:)` builds the mode's agent on the chat with the router's
  inputs as the agent's `inputs:`; `Route#mode_class` is the class.
- `Router.instructions` mirrors `Agent.instructions`: a string, a block, or
  the conventional template `app/prompts/<router_path>/instructions.txt.erb`
  with keyword locals; `prompt(name, **locals)` inside a block renders a
  template from the same directory.
- The `:chat` classifier backend with the built-in routing frame, the
  selection schema, and `chat_factory:`.
- `DeclarationError`, `UnknownMode` (a `KeyError`), and `ContractError`.
- The `:judge` classifier backend on `RubyLLM.judge`: one `choice` question
  over the modes, `confidence` as the concentration of the probability
  distribution, `provider:` and `judge:` options. A RubyLLM release without
  `RubyLLM.judge` rejects the backend at `new` unless `judge:` is given.
- A classifier that responds to `trace` is traced by its own answer.
- `truncate message:, history_entry:` caps, in characters, what reaches any
  classifier: the message keeps its head and tail, each history entry its
  head, with a marker for the cut. Defaults 30,000 and 2,000; `nil`
  disables a cap. Jev rejects a request over about 170k characters.
- The `Classifier failed` reason carries the first line of the exception's
  message after the class, so a provider's error body reaches the logged
  route.
- Three acceptance examples under `examples/`, run as integration tests.
