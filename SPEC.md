# ruby_llm-modes — specification (v0.1)

Route one conversation between agents: one decision per turn, traced.

A **mode** is a `RubyLLM::Agent` with a routing description. A **router**
declares the modes, a fallback, and a classifier; on every turn it returns a
**route**: which mode handles the message, why, and what the classifier
actually said. The app applies the mode to its chat.

Status: agreed design, implemented in v0.1.0 (see the decisions at the
bottom). Duck (`~/code/rails/duck`) is the
first consumer; its migration lives in Duck's `WORKLOG-modes.md`.

## 1. Vocabulary

| Term       | Meaning                                                            |
|------------|--------------------------------------------------------------------|
| Mode       | An agent class that can take one turn of an existing chat          |
| Router     | The declaration: modes, fallback, classifier, guidance             |
| Decision   | What the classifier said, untouched                                |
| Route      | What the router decided, with the decision attached                |
| Classifier | A backend that turns (message, history, modes) into a Decision     |

Namespace `RubyLLM::Modes`; gem `ruby_llm-modes`; depends on
`ruby_llm >= 2.0.0, < 3` and `schematist ~> 1.1`. Plain Ruby in `lib/`, no
ActiveSupport, no Rails hooks, no prompt files.

## 2. Modes

```ruby
module RubyLLM::Modes::Mode      # extend into an Agent class
  mode_description "..."         # required for routing; multi-line ok
  mode_name "tutor"              # optional override
end

class RubyLLM::ModeAgent < RubyLLM::Agent
  extend RubyLLM::Modes::Mode
end
```

- The gem never adds macros to `RubyLLM::Agent` itself. An app subclasses
  `RubyLLM::ModeAgent` or extends `RubyLLM::Modes::Mode` into its own base
  (Duck: `ApplicationModeAgent < ApplicationAgent`).
- `mode_name` default: class name with the trailing `Agent` removed,
  namespaces kept, underscored. `TutorAgent` → `"tutor"`,
  `Chat::TutorAgent` → `"chat/tutor"`, `TutorModeAgent` → `"tutor_mode"`.
- A mode is applied to a chat by the app with Agent's public constructor:
  `TutorAgent.new(chat:, persist_instructions: false, **inputs)`. See §8.

## 3. Router declaration

```ruby
class ChatModeRouter < RubyLLM::Modes::Router
  inputs :user, :card                       # runtime context, as in Agent

  mode TutorAgent                           # description from mode_description
  mode ClarifyAgent
  mode ManageCardsAgent, "Manages flashcards"          # inline description wins
  mode ShowtimeAgent, if: -> { user.showtime_enabled? } # availability per call
  mode Chat::ReviewAgent, as: :review                  # registration name

  guidance do                               # optional, string or block
    text = "Duck is an English-learning app. Route by the learner's intended action."
    text += "\nThe learner has a flashcard open on screen." if card
    text
  end

  history 6                                 # optional; default: all given
  fallback TutorAgent, below_confidence: 0.6
  classify with: :chat, model: "gemini-3.5-flash-lite"
  on_error { |error| Rails.error.report(error, handled: true) }   # optional
end
```

Macros:

- `inputs *names` — declared like Agent inputs. Available as methods inside
  `if:`, `guidance`, and `prompt` blocks, and passed to a custom classifier.
- `mode klass, description = nil, as: nil, if: nil` — registers a mode.
  `klass` must be a `RubyLLM::Agent` subclass, registered once per router
  (v0.1: one registration per class, so `fallback klass` is unambiguous).
  Without `description` it must respond to `mode_description`. `as:` sets
  the registration name; default `klass.mode_name` if it responds to it,
  else the derivation in §2. `if:` is a lambda run on the router instance.
- `guidance text = nil, &block` — cross-mode routing text. Both backends
  receive the same resolved string.
- `prompt name = nil, &block` — replaces the chat backend's built-in system
  prompt (§6). Incompatible with `:judge`; validated at `new`.
- `history n` — keep only the last `n` history entries.
- `fallback klass, below_confidence: nil` — required. The mode used when
  the classifier is ignored. `below_confidence` nil disables the threshold.
- `classify with:, model: nil, **options` — `with:` is `:chat`, `:judge`, or
  any object responding to `call` (§5). `classify model: "..."` alone
  means `:chat`. `options` go to the built-in backend (`chat_factory:` for
  `:chat`).
- `on_error(&block)` — receives every classifier exception; default no-op.

Inheritance: subclassing a router copies its declarations (as Agent does);
changes in the subclass never touch the parent. `mode` appends to the
inherited list; `fallback`, `classify`, `guidance`, `prompt`, `history`,
`on_error` replace. `mode_description` is **not** inherited: every mode
declares its own (`ApplicationModeAgent` has none and is not routable).
`mode_name` is derived per class unless overridden on that class.

## 4. Router instance

```ruby
router = ChatModeRouter.new(user:, card:)
router.modes                 # available registrations for this call, in declaration order
router.call(message, history: [], classifier: nil)   # → Route
router.explicit("showtime")                          # → Route
```

Validation happens in `new`, not at class definition (there is no reliable
"end of declaration" hook). Errors are `RubyLLM::Modes::DeclarationError`:

- no `fallback`; fallback not registered with `mode`; fallback has `if:`
- duplicate registration names
- a mode without a description
- `classify with: :judge` when `RubyLLM::Judge` is not defined
- `prompt` declared together with `:judge`
- the same class registered twice
- a declared input not passed to `new` (`ArgumentError`, the router's own
  rule; Agent does not check, its blocks fail later with `NameError`).
  `card: nil` is passing it; the key must be present.

Availability invariants:

- The fallback is always available.
- `explicit(name)` respects `if:`; an unavailable or unknown name raises
  `RubyLLM::Modes::UnknownMode` (a `KeyError`).
- If the fallback is the only available mode, the classifier is not called;
  the route is `level: "fallback"`, `reason: "No other mode available"`.
- Every mode a Route returns is available for that call.

`history:` entries are `{ role:, content: }` hashes, `RubyLLM::Message`s, or
strings. The router normalises them to `[{ role: Symbol | nil, content:
String }]` (a string becomes `{ role: nil, content: }`), applies `history n`,
and only then calls any backend; custom classifiers see the normalised
form. `classifier:` overrides the declared backend for this call (tests,
shadow runs).

## 5. Classifier contract

```ruby
Decision = Data.define(:mode_name, :confidence, :reason, :probabilities)
# mode_name: String or nil; confidence: Float 0..1 or nil (nil = "not scored");
# reason: String or nil; probabilities: { name => Float } or nil
# A confidence that is NaN or outside 0..1 is a contract violation:
# the router raises RubyLLM::Modes::ContractError through the "classifier
# raised" path (fallback route, error set), never compares it.

classifier.call(message:, history:, modes:, guidance:, inputs:) # → Decision
# modes: [[name, description], ...] available for this call
```

Built-in backends:

- `:chat` — `RubyLLM.chat(model:)` with the selection schema
  (`mode` enum of names, `confidence` number, `reason` string) and the
  system prompt of §6. The latest message is also sent as the user turn.
  `chat_factory: ->(model:) { ... }` replaces the chat constructor (Duck:
  `Llm.chat`, for its usage ledger). `confidence` is the model's
  self-report.
- `:judge` — `RubyLLM::Judge` with `inputs :modes` and one
  `choice :mode, question, -> { modes.to_h }`; input
  `{ message:, history: }`; `guidance` appended to the question. `confidence`
  is the distribution concentration; `reason` is nil; `probabilities` set.
  **Not in v0.1.0**: written against a released RubyLLM that ships `Judge`,
  tested against the real API, not a fake. Until then `with: :judge` raises
  `DeclarationError` ("RubyLLM::Judge not available").

A custom classifier is any object with that `call`. A class is accepted
only if the class itself responds to `call`; there is no implicit `new`.

Tracing (`Route#classifier`): a built-in backend records what actually ran,
`{ with: "chat", model: "..." }`; a custom object records `{ with:
"custom", model: nil }`; when no backend was called (explicit,
fallback-only shortcut) it is nil. A `classifier:` override follows the
same rule for the object actually used, never the declared one. A shadow
classifier that runs two backends logs the comparison itself; `Decision`
has no slot for it in v0.1.

Confidence scales differ between backends; `below_confidence` is tuned per
backend, never shared.

## 6. Prompt assembly (`:chat` only)

The gem holds a short frame as a Ruby string. For two modes it produces:

```
You route the latest user message to one of the modes below.
Choose exactly one. Use the conversation only to understand what the
latest message refers to. Do not answer the user.

<guidance, if any>

Modes:
- tutor: Explains words and grammar, corrects the learner, keeps the
  conversation going. A bare word or phrase is a request to explain it.
- card: Creates, edits, or deletes flashcards. Only when the learner asks
  for it, never inferred from a word alone.

Conversation:
user: what does "reluctant" mean?
assistant: Reluctant means unwilling or hesitant ...

Latest message:
add it to my cards

Return the structured selection: mode, confidence from 0 to 1, reason.
```

Text sources, lightest to fullest:

1. `mode_description` on the agent
2. inline description in `mode klass, "..."`
3. `guidance` on the router (string or block; inputs visible)
4. `prompt` on the router: a template name resolved with
   `RubyLLM.render_prompt(name, modes:, guidance:, history:, message:, **inputs)`
   from the app's own `app/prompts/`, or a block returning the full text
   (same locals as methods). Replaces the frame entirely.

## 7. Route

```ruby
Route = Data.define(:mode, :mode_name, :level, :reason, :decision,
                    :routing_ms, :classifier, :error)
# mode: class; mode_name: registration name; level: "explicit" | "classifier" | "fallback"
# decision: Decision or nil (explicit); classifier: { with:, model: } or nil
# error: Exception or nil, never serialised
```

Checks run in this order; the first that fails names the reason.

| # | Situation                                        | level          | reason                        | decision |
|---|--------------------------------------------------|----------------|-------------------------------|----------|
| 0 | `explicit(name)`                                 | `"explicit"`   | `"Explicit mode requested"`   | nil      |
| 1 | only the fallback is available                   | `"fallback"`   | `"No other mode available"`   | nil      |
| 2 | classifier raised, or violated the contract      | `"fallback"`   | `"Classifier failed: <class>"`| nil, `error` set |
| 3 | decision names an unknown or unavailable mode    | `"fallback"`   | `"Unknown mode <name>"`       | kept     |
| 4 | threshold on, confidence nil                     | `"fallback"`   | `"Confidence not scored"`     | kept     |
| 5 | threshold on, confidence below it                | `"fallback"`   | `"Below confidence threshold"`| kept     |
| 6 | otherwise                                        | `"classifier"` | decision.reason               | kept     |

Threshold off (`below_confidence` nil): rows 4 and 5 are skipped and a
known, available mode is accepted whatever its confidence.

`routing_ms` wraps the classifier call and is present on every non-explicit
route. `to_h` gives string keys and drops `mode` (class) and `error`:

```ruby
{ "mode" => "tutor", "level" => "fallback", "reason" => "Below confidence threshold",
  "duration_ms" => 812, "classifier" => { "with" => "chat", "model" => "gemini-3.5-flash-lite" },
  "decision" => { "mode" => "showtime", "confidence" => 0.42, "reason" => "..." } }
```

## 8. Applying a mode (app responsibility)

The router never touches the chat. The app applies the mode:

```ruby
route = ChatModeRouter.new(user:, card:).call(message.content, history:)
route.mode.new(chat:, persist_instructions: false, user:, card:)
chat.complete
```

What Agent's constructor does to an existing chat (verified in
`agent.rb`, `apply_configuration`): it **adds** configuration, it does not
reset it. `with_tools` is called only when the mode declares tools,
`with_schema` only when it declares a schema, `with_thinking` only when
declared. Instructions replace the system message unless declared with
`append: true`; with `persist_instructions: false` a Rails chat record keeps
them in memory only.

Verified on a real `RubyLLM::Chat` (rc4, no provider calls): after two
modes with `append: true` the chat holds the base prompt **and both** mode
instructions; `thinking effort:` from the first mode survives into the
second; `with_tools(nil)` and `with_schema(nil)` do clear;
`with_instructions(base)` without `append:` drops every appended
instruction and keeps only the base; there is no way to unset thinking
(`with_thinking(false)` raises for models without an "off" control).

Consequences the app must handle:

- Apply a mode to a chat whose per-turn configuration is fresh. A Rails
  record loaded for the turn is fresh (Duck loads `Chat.find` in the job).
- A long-lived in-memory chat must be restored to its base configuration
  before the next mode:

  ```ruby
  chat.with_instructions(base_prompt)   # replaces: base stays, mode instructions go
      .with_tools(nil)
      .with_schema(nil)
  ```

  and every mode must declare `thinking` explicitly (it replaces; nothing
  can unset it), or the app sets a baseline `with_thinking(...)` in the
  same reset.
- Declare mode instructions with `append: true` when the chat carries a
  base system prompt that must survive.

If real integrations need more than this reset, this section is the first
thing to revisit (a `Route#apply` with reset semantics), not the router.

## 9. Acceptance examples for v0.1.0

Three small programs in `examples/`, also run as integration tests with a
fake `:chat` backend:

1. **Contextual routing.** Router with `inputs :card`, `guidance` block that
   mentions the open card; assert the resolved prompt contains the sentence
   only when `card` is given, for both a fake chat backend and a custom
   classifier.
2. **Tool mode → clarification on one chat.** On a real `RubyLLM::Chat`
   with only the provider call stubbed: base instructions, then
   `ManageCardsAgent` (tools, schema, `thinking effort: :high`), then the
   reset of §8 and `ClarifyAgent` (no tools, `thinking effort: :low`).
   Assert the system messages are exactly base + Clarify's, tools empty,
   schema nil, thinking `{ effort: :low }`.
3. **Custom classifier with a traced fallback.** A classifier returning
   `showtime` at 0.42 under a 0.6 threshold; assert `route.mode ==
   TutorAgent`, `level == "fallback"`, `decision.mode_name == "showtime"`,
   `decision.confidence == 0.42`, and `to_h` carries both.

Plus unit tests for every row of the §7 table, every `DeclarationError`,
the name derivation, `explicit` availability, and the fallback-only
shortcut.

## 10. Non-goals

- No registry, autoload folder, Railtie, generator, or global configuration.
- No prompt files in the gem.
- No chat mutation: no `apply`, no hooks into `complete`.
- No tool budget, badges, or usage accounting; those are app concerns.
- Sugar such as `chat.with_router(...)` only if consumers repeat the same
  three lines everywhere.

## 11. Decisions made while implementing (v0.1.0)

Where the spec was silent the simplest reading was taken. None of these
add API.

- **No `classify` declared** means `:chat` with RubyLLM's configured
  default model (`RubyLLM.chat(model: nil)`).
- **`classify` validation** also raises `DeclarationError` for an unknown
  backend symbol and for a `with:` object that does not respond to `call`.
  For `:judge`, the `prompt` conflict is checked before Judge availability.
- **`new` with an undeclared keyword** raises `ArgumentError`, like a
  missing one.
- **`Unknown mode <name>`** renders a nil `mode_name` as `Unknown mode nil`.
- **`routing_ms` on the fallback-only shortcut** is `0`; no backend ran.
- **`on_error`** runs on the router instance (`instance_exec`), so inputs
  are visible inside the block. An exception raised by the handler itself
  propagates.
- **History entries** that respond to `to_llm` (Rails message records) are
  accepted and normalised through the `RubyLLM::Message` they return. Any
  other object raises `ArgumentError`. Hash keys may be symbols or strings.
- **Contract check** rejects, besides the confidence rules of §5, a
  `mode_name` that is neither a String nor nil, and a return value that is
  not a `Decision`. Any `Numeric` confidence in 0..1 is accepted.
- **`Decision#to_h`** is `{ "mode", "confidence", "reason" }` plus
  `"probabilities"` only when set. **`Route#to_h`** keeps nil slots
  (`"duration_ms" => nil` on an explicit route).
- **Trace model** for `:chat` is the id of the model the built chat resolved
  to, once a chat was built; before that (or when the factory returns an
  object without `model`) it is the declared string, possibly nil.
- **Chat backend parsing**: a reply that is not a JSON object raises
  `ContractError`; a non-numeric `confidence` is passed through and rejected
  by the router's contract check; a JSON `Integer` confidence becomes a
  Float. JSON parse errors surface as `Classifier failed: JSON::ParserError`.
- **Prompt rendering**: the gem does not wrap text. A multi-line description
  is rendered with continuation lines indented by two spaces. `Conversation:`
  is omitted when the history is empty; guidance is omitted when blank. An
  entry with a nil role is a bare line.
- **`mode_description`** strips surrounding whitespace. **`mode_name`
  derivation** keeps a segment that is exactly `Agent` (`Foo::Agent` →
  `"foo/agent"`) and returns nil for an anonymous class, which the router
  reports as "no registration name" unless `as:` is given.
- **`guidance`**: strings are stripped; a blank result is nil.
- **`Router#modes`** returns `Registration` values (`klass`, `name`,
  `description`, `condition`), evaluated on every call.
- **`Router.validate!`** is public so an app can check a declaration at boot
  without building an instance.
- **`Router#classifier`** and **`Router#inputs`** are readable on the
  instance.

