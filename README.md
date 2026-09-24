# ruby_llm-modes

Route one conversation between agents: one decision per turn, traced.

A chat app rarely has one assistant. The same conversation needs a tutor
one turn, a tool-wielding card manager the next, and a short clarifying
question after that. `ruby_llm-modes` lets you declare those agents as
**modes** of one router, ask the router which mode should take the
current turn, and get back a **route** that says which mode, why, and what
the classifier actually said. The router never touches the chat; your app
applies the mode.

```ruby
route = ChatModeRouter.new(user:, card:).call(message.content, history:)
route.mode(chat:).complete

logger.info route.to_h
# {"mode_name"=>"tutor", "decided_by"=>"fallback", "reason"=>"Below confidence threshold",
#  "decision"=>{"mode_name"=>"showtime", "confidence"=>0.42, "reason"=>"..."},
#  "duration_ms"=>812, "classifier"=>{"with"=>"chat", "model"=>"gemini-3.5-flash-lite"}}
```

Plain Ruby on top of [RubyLLM](https://rubyllm.com) 2.x. No Rails hooks,
no registry, no prompt files.

## Installation

```ruby
gem "ruby_llm-modes"
```

Requires `ruby_llm >= 2.0` and Ruby 3.2 or newer.

## Modes

A mode is a `RubyLLM::Agent` with a routing description. Subclass
`RubyLLM::ModeAgent`, or extend `RubyLLM::Modes::Mode` into your own agent
base class.

```ruby
class TutorAgent < RubyLLM::ModeAgent
  mode_description <<~TEXT
    Explains words and grammar, corrects the learner, keeps the
    conversation going. A bare word or phrase is a request to explain it.
  TEXT

  instructions "You are a patient English tutor."
end

class ManageCardsAgent < RubyLLM::ModeAgent
  mode_description "Creates, edits, or deletes flashcards. Only when the learner asks for it."
  mode_name "cards"          # optional; default derived from the class name

  instructions "Manage the learner's flashcards with the tools."
  tools CreateCard, DeleteCard
  thinking effort: :high
end
```

The default `mode_name` is the class name with the trailing `Agent`
removed, namespaces kept, underscored: `TutorAgent` is `"tutor"`,
`Chat::TutorAgent` is `"chat/tutor"`, `TutorModeAgent` is `"tutor_mode"`.
Neither `mode_description` nor `mode_name` is inherited: every routable
class declares its own description.

A mode takes one turn of a chat that already has its own system prompt, so
`instructions` in a mode defaults to `append: true` and `persist: false`:
the mode's prompt is added after the chat's and, on a Rails chat record,
kept out of the stored history. Declare `append: false` or `persist: true`
to override. The defaults apply to explicit `instructions` declarations
only; a conventional `instructions.txt.erb` template with no declaration
keeps Agent's defaults, so declare `instructions` in a mode.

## The declaration

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

  history last: 6                           # optional; default: all given
  fallback TutorAgent, below_confidence: 0.6
  classify_with :chat, model: "gemini-3.5-flash-lite"
  on_error { |error| Rails.error.report(error, handled: true) }   # optional
end
```

- `inputs` are required keywords of `new` (`card: nil` counts as passed)
  and become methods inside `if:`, `guidance`, and `prompt` blocks.
- `mode` registers an agent class once. Without an inline description the
  class must have a `mode_description`. The router's declaration wins over
  the class's: an inline description overrides `mode_description`, and
  `as:` overrides `mode_name`, which in turn overrides the name derived
  from the class.
- `fallback` is required. It is the mode used whenever the classifier is
  ignored: it raised, named an unknown or unavailable mode, or scored below
  `below_confidence`. Pass no threshold to accept any confidence.
- `classify_with` is required: `:chat`, `:judge`, or a classifier object
  (see [Plugging a custom classifier](#plugging-a-custom-classifier)).
- Subclassing a router copies its declarations. `mode` appends to the
  inherited list; the other macros replace.

The declaration is validated when a router is built with `new`, and every
problem is a `RubyLLM::Modes::DeclarationError`: no fallback, no
classifier, a fallback
that is not registered or has an `if:`, duplicate names, a mode without a
description, the same class registered twice, or an unavailable backend.

### Routing a turn

```ruby
router = ChatModeRouter.new(user: current_user, card: open_card)
router.modes                    # registrations available for this call
route = router.call(message, history: chat.messages)
route = router.force("showtime")      # the app chose the mode; raises UnknownMode if unavailable
```

`call` lets the classifier decide. `force` is for the turns the app has
already decided, such as a button or a command that starts a mode by
name: no classifier runs, `if:` still applies, and the result is a
`Route` like any other, so the code that applies and logs a route stays
the same.

`history:` entries are `{ role:, content: }` hashes, `RubyLLM::Message`
objects, Rails message records responding to `to_llm`, or plain strings.
The router normalises them before any backend sees them. `history last: n`
keeps the last `n` entries as given, whatever their roles; `history :all`,
the default, keeps every entry, and a subclass can declare it to undo an
inherited limit.

A `Route` has `mode_class`, `mode_name`, `decided_by` (`"caller"`,
`"classifier"`, or `"fallback"`), `reason`, the classifier's `decision`,
`duration_ms`, a `classifier` trace (`{ with:, model: }`), `error`, and the
router's `inputs`. `route.mode(chat:)` is the mode as an agent on that
chat (see [Applying a mode](#applying-a-mode)). `to_h`
is the same fields with string keys, for logs, minus the class, the error,
and the inputs; `Decision#to_h` follows the same rule.

The route is decided by the first rule that applies:

| Situation                                        | decided_by     | reason                         |
|--------------------------------------------------|----------------|--------------------------------|
| `force(name)`                                    | `"caller"`     | `"Mode requested by caller"`   |
| only the fallback is available                   | `"fallback"`   | `"No other mode available"`    |
| classifier raised, or violated the contract      | `"fallback"`   | `"Classifier failed: <class>"` |
| decision names an unknown or unavailable mode    | `"fallback"`   | `"Unknown mode <name>"`        |
| threshold on, confidence nil                     | `"fallback"`   | `"Confidence not scored"`      |
| threshold on, confidence below it                | `"fallback"`   | `"Below confidence threshold"` |
| otherwise                                        | `"classifier"` | the decision's reason          |

Every mode a route returns is available for that call, and the classifier
is not called when the fallback is the only available mode.

## Backends and what `confidence` means

### `:chat`

One structured-output turn on `RubyLLM.chat(model:)`. The system prompt
is a short frame: your `guidance`, the modes with their descriptions, and
the conversation. The latest message is the user turn.
The model returns `mode` (an enum of the available names), `confidence`,
and `reason`.

`confidence` is the model's **self-report** from 0 to 1. It is useful for
telling a hedge from a clear call, but it is not calibrated, and its scale
depends on the model. Tune `below_confidence` per model by looking at
routes in your logs; do not carry a threshold from one backend to another.

Options:

- `chat_factory: ->(model:) { ... }` replaces the chat constructor, for
  apps that route every LLM call through their own wrapper.
- `prompt "routers/chat_mode"` renders `app/prompts/routers/chat_mode.txt.erb`
  through `RubyLLM.render_prompt` with `modes`, `guidance`, `history`,
  `message`, and the inputs as locals, and uses the result as the whole
  system prompt. `prompt { ... }` does the same with a block that sees the
  same names as methods.

### `:judge`

One `RubyLLM.judge` call with a single `choice` question whose options are
the modes and their descriptions. The state is data, not a prompt: your
`guidance`, the conversation as `{ role, content }` entries, and the
latest message. The answer is a probability per mode; the decision's
`mode_name` is the most likely one and `probabilities` carries the
distribution.

`confidence` is the **concentration** of that distribution (1.0 when one
mode takes all the mass, 0.0 when the modes are equally likely), a
different scale from the chat backend's self-report, which is why
thresholds are per backend. There is no free text, so `reason` is nil and
a clarification has to be a mode of its own.

Options:

- `model:` and `provider:` are passed to `RubyLLM.judge` as given;
  without them RubyLLM's own defaults apply (`default_judgment_model`).
- `judge:` replaces `RubyLLM.judge` with any callable taking the same
  arguments and returning a `RubyLLM::Judgment`, for tests.

`RubyLLM.judge` ships in RubyLLM after 2.0.0. On a release without it,
`classify_with :judge` raises `DeclarationError` when the router is built,
unless `judge:` is given. `prompt` cannot be declared with this backend.

## Applying a mode

The router never touches the chat. `route.mode(chat:)` does: it is the
mode's `Agent.new(chat:, inputs: route.inputs)`, so it configures the chat
you pass in and returns the agent wrapping it.

```ruby
route.mode(chat:).complete
```

The router's inputs are handed to the agent as its `inputs:`. The agent
takes the names it declared with `inputs` and ignores the rest, so a mode
declares only what it uses. Extra keywords go to `Agent.new` as given:
`route.mode(chat:, session:)`.

Run the turn through the agent, not the chat: `agent.complete` is
`chat.complete` inside the agent's `rescue_from` handlers, while
`chat.complete` skips them.

Agent's constructor **adds** configuration to the chat: mode instructions
append to the chat's system prompt (see [Modes](#modes)); tools, schema,
and thinking are set only when the mode declares them. The usual setup
gives each turn its own chat object, so this is all there is to it: a
Rails chat record loaded for the turn builds a fresh `RubyLLM::Chat` from
its stored messages, and a `RubyLLM.chat` created for the turn is fresh by
definition. Nothing from the previous mode carries over but the messages.

### Reusing one chat object for several turns

A script, a console session, or a job that runs two modes back to back on
one `RubyLLM::Chat` keeps the previous mode's configuration: its appended
instructions, tools, schema, and thinking. Two ways to start the next turn
clean:

- `route.mode` with no `chat:` builds a fresh chat through Agent; the app
  copies over the user and assistant messages it wants to keep.
- Restore the same object to its base configuration before the next mode:

  ```ruby
  chat.with_instructions(base_prompt)   # base stays, appended mode instructions go
      .with_tools(nil)
      .with_schema(nil)
  ```

  Thinking enabled by a mode stays on until the next `with_thinking`.
  Add `with_thinking(false)` to the reset when the model has an off
  control in RubyLLM's registry (Anthropic and Gemini 2.5 models do;
  `with_thinking(false)` raises for a model without one), or set the
  baseline `with_thinking(...)` you want every mode to start from.

`examples/tool_mode_to_clarification.rb` shows the reset on a real
`RubyLLM::Chat`.

## Plugging a custom classifier

A classifier is any object with this method:

```ruby
class KeywordClassifier
  def call(message:, history:, modes:, guidance:, inputs:)
    name = modes.map(&:name).find { |candidate| message.downcase.include?(candidate) }
    RubyLLM::Modes::Decision.new(mode_name: name, confidence: name ? 1.0 : nil, reason: "keyword match")
  end
end

class ChatModeRouter < RubyLLM::Modes::Router
  # ...
  classify_with KeywordClassifier.new
end
```

- `modes` is the `Registration` values available on this call, the same
  objects `router.modes` returns: each has `name`, `description`, and
  `klass`, the agent class. `history` is the normalised
  `[{ role:, content: }]`; `guidance` is the resolved string or nil;
  `inputs` is the hash passed to `new`.
- Return a `Decision`. `mode_name` is a String or nil, `confidence` is a
  number from 0 to 1 or nil for "not scored", `reason` and
  `probabilities` are optional. Anything else is a contract violation and
  routes to the fallback with a `ContractError` on `route.error`.
- A class is accepted only if the class itself responds to `call`; the
  router never calls `new` for you.
- Custom classifiers are traced as `{ with: "custom", model: nil }`, unless
  the classifier responds to `trace` and returns its own `{ with:, model: }`.

Pass `classifier:` to `call` to replace the declared backend for one call,
for tests or shadow runs:

```ruby
router.call(message, history:, classifier: FakeClassifier.new(decision))
```

## Examples

`examples/` holds three runnable programs that double as the integration
tests: contextual routing through `guidance`, a tool mode followed by a
clarification mode on one chat, and a custom classifier whose
low-confidence decision falls back with a full trace.

```
bundle exec ruby examples/contextual_routing.rb
bundle exec rake
```

## License

MIT. See [LICENSE.txt](LICENSE.txt).
