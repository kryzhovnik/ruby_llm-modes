# ruby_llm-modes

One chat, one configuration per turn: a small classifier picks the mode before each answer.

A **mode** is the configuration of one turn: instructions, tools, model, thinking. Neighbouring messages in one chat can want very different ones, and putting every tool and instruction into one system prompt makes every turn pay for all of them. Instead the conversation stays one chat with one history; before each answer a small classifier reads the latest message and a window of history, the router picks a mode, and your app applies it to the chat. The model that answers never sees another mode's tools or instructions, and the decision is a value you can log and test: which mode, why, and what the classifier actually said.

```ruby
route = SupportRouter.new(customer:, order:).call(message.content, history:)
route.mode(chat:).complete

route.to_h
# {
#   "mode_name" => "help",
#   "decided_by" => "fallback",
#   "reason" => "Below confidence threshold",
#   "decision" => {
#     "mode_name" => "returns",
#     "confidence" => 0.42,
#     "reason" => nil,
#     "probabilities" => { "help" => 0.31, "returns" => 0.45, "orders" => 0.24 }
#   },
#   "duration_ms" => 812,
#   "classifier" => { "with" => "judge", "model" => "jev-1.13.0" }
# }
```

Plain Ruby on top of [RubyLLM](https://rubyllm.com) 2.x. No Rails hooks, no registry, no built-in prompt files.

## Installation

```ruby
gem "ruby_llm-modes"
```

Requires `ruby_llm >= 2.0` and Ruby 3.2 or newer.

## Modes

A mode is a `RubyLLM::Agent` with a routing description. Subclass `RubyLLM::ModeAgent`, or extend `RubyLLM::Modes::Mode` into your own agent base class.

```ruby
class HelpAgent < RubyLLM::ModeAgent
  mode_description <<~TEXT
    Answers questions about delivery, payment, sizes, and store policy.
    No account access: a question about a specific order is not for this mode.
  TEXT

  instructions "You are a friendly support assistant for an online store. Keep answers short."
  thinking effort: :low
end

class ReturnsAndExchangesAgent < RubyLLM::ModeAgent
  mode_description "Returns, exchanges, and refunds for an order the customer already has. Only when the customer asks for one."
  mode_name "returns"        # optional; default derived from the class name

  instructions "Handle the return or exchange with the tools. Check the policy before promising anything."
  tools FindOrder, CreateReturn, ExchangeItem
  thinking effort: :high
end
```

The default `mode_name` is the class name with the trailing `Agent` removed, namespaces kept, underscored: `HelpAgent` is `"help"`, `Support::HelpAgent` is `"support/help"`. Neither `mode_description` nor `mode_name` is inherited.

A mode takes one turn of a chat that already has its own system prompt, so `instructions` in a mode defaults to `append: true, persist: false`: the mode's prompt follows the chat's and stays out of a Rails record's stored history. Declare either option to override. The defaults apply to an explicit `instructions` declaration only, so declare one in every mode.

## The declaration

```ruby
class SupportRouter < RubyLLM::Modes::Router
  inputs :customer, :order                  # runtime context, as in Agent

  mode HelpAgent                            # description from mode_description
  mode ClarifyAgent
  mode ReturnsAndExchangesAgent
  mode OrdersAgent, "Order status, tracking, and delivery dates"   # inline description wins
  mode ConciergeAgent, if: -> { customer.vip? }                    # availability per call
  mode Support::EscalationAgent, as: :escalate                     # registration name

  instructions do                           # optional; string, block, or template
    text = "Route by what the customer wants done now."
    text += "\nThe customer is looking at order #{order.number}." if order
    text
  end

  history last: 6                           # optional; default: all given
  truncate message: 30_000, history_entry: 2_000   # optional; these are the defaults
  fallback HelpAgent, below_confidence: 0.6
  classify_with :chat, model: "gemini-3.5-flash-lite"
  on_error { |error| Rails.error.report(error, handled: true) }   # optional
end
```

- `inputs` are required keywords of `new` (`order: nil` counts as passed) and become methods inside `if:` and `instructions` blocks.
- `instructions` takes the same forms as in an Agent: a string, a block, or the conventional `app/prompts/support_router/instructions.txt.erb` template with keyword locals. It resolves on the router instance, and every backend receives the same string.
- `history :all` is the default; it lets a subclass undo an inherited `last:`.
- `truncate` cuts the routed message to its first and last half and each history entry to its head, with a marker for the cut. `nil` disables a cap. Keep `entries × history_entry + message` under your provider's request limit.
- `fallback` is the mode used whenever the classifier is ignored (see the [outcome table](#outcomes)). Pass no threshold to accept any confidence.
- Subclassing copies the declarations. `mode` appends to the inherited list; the other macros replace.

The declaration is validated when the router is built with `new`; every problem raises `DeclarationError`.

## Routing a turn

```ruby
router = SupportRouter.new(customer: current_customer, order: current_order)
router.modes                    # modes available for this call
route = router.call(message, history: chat.messages)
route = router.force("returns")       # the customer pressed "Return an item"; raises UnknownMode if unavailable
```

`call` lets the classifier decide. `force` is for the turns the app has already decided, such as a button that starts a mode by name: no classifier runs, `if:` still applies, and the result is a `Route` like any other. `history:` entries are `{ role:, content: }` hashes, `RubyLLM::Message` objects, Rails message records responding to `to_llm`, or plain strings. The classifier is not called when the fallback is the only available mode.

## Applying a mode

`route.mode(chat:)` is the mode's `Agent.new(chat:, inputs: route.inputs)`: it configures the chat you pass in and returns the agent wrapping it. The agent takes the inputs it declared and ignores the rest. Extra keywords go to `Agent.new` as given: `route.mode(chat:, session:)`.

```ruby
route.mode(chat:).complete
```

Run the turn through the agent, not the chat, so the agent's `rescue_from` handlers apply. Agent's constructor **adds** configuration to the chat: mode instructions append to the system prompt; tools, schema, and thinking are set only when the mode declares them. A chat built for the turn (a Rails chat record, or a fresh `RubyLLM.chat`) needs nothing else. A chat object reused across turns keeps the previous mode's configuration and needs a reset before the next mode; `examples/tool_mode_to_clarification.rb` shows one.

## Backends and what `confidence` means

### `:chat`

One structured-output turn on `RubyLLM.chat(model:)`. The system prompt is a fixed frame around your `instructions`, the modes, and the conversation; the latest message is the user turn. The model returns `mode` (an enum of the available names), `confidence`, and `reason`.

`confidence` is the model's **self-report** from 0 to 1. It tells a hedge from a clear call, but it is not calibrated, and its scale depends on the model. Tune `below_confidence` per model from your logs, and do not carry a threshold from one backend to another.

`chat_factory: ->(model:) { ... }` replaces the chat constructor. The frame is not configurable: subclass `RubyLLM::Modes::Classifiers::Chat` and override `self.prompt`, or plug a custom classifier.

### `:judge`

One `RubyLLM.judge` call with a single `choice` question whose options are the modes and their descriptions. The answer is a probability per mode: the decision's `mode_name` is the most likely one and `probabilities` carries the distribution.

`confidence` is the **concentration** of that distribution: 1.0 when one mode takes all the mass, 0.0 when the modes are equally likely. There is no free text, so `reason` is nil and a clarification has to be a mode of its own.

`model:` and `provider:` are passed to `RubyLLM.judge` as given; without them RubyLLM's defaults apply. `judge:` replaces `RubyLLM.judge` with any callable taking the same arguments and returning a `RubyLLM::Judgment`. `RubyLLM.judge` is not in ruby_llm 2.0.0; it is on RubyLLM's main branch. On a release without it, `classify_with :judge` raises `DeclarationError` unless `judge:` is given.

## Custom classifiers

A classifier is any object with this method:

```ruby
class KeywordClassifier
  def call(message:, history:, modes:, instructions:, inputs:)
    name = modes.map(&:name).find { |candidate| message.downcase.include?(candidate) }
    RubyLLM::Modes::Decision.new(mode_name: name, confidence: name ? 1.0 : nil, reason: "keyword match")
  end
end

classify_with KeywordClassifier.new
```

A class is accepted only if the class itself responds to `call`; the router never calls `new`. Pass `classifier:` to `call` to replace the declared backend for one call, for tests or shadow runs:

```ruby
router.call(message, history:, classifier: FakeClassifier.new(decision))
```

## Reference

### Classifier contract

`call(message:, history:, modes:, instructions:, inputs:)` returns a `Decision`.

- `message` is the routed message, cut to the `truncate` cap.
- `history` is `[{ role:, content: }]`, normalised and cut.
- `modes` is what `router.modes` returns: the modes available on this call, each responding to `name`, `description`, and `klass`.
- `instructions` is the resolved string or nil; `inputs` is the hash passed to `new`.
- `Decision`: `mode_name` is a String or nil, `confidence` a number from 0 to 1 or nil for "not scored", `reason` and `probabilities` optional. Anything else is a `ContractError` and routes to the fallback.
- A classifier responding to `trace` is traced by its own `{ with:, model: }`; otherwise as `{ with: "custom", model: nil }`.

### Route

| Field         | Value                                                        |
|---------------|--------------------------------------------------------------|
| `mode_class`  | the agent class                                              |
| `mode_name`   | its registration name                                        |
| `decided_by`  | `"caller"`, `"classifier"`, or `"fallback"`                  |
| `reason`      | why this mode (see below)                                    |
| `decision`    | the classifier's `Decision`, or nil when none ran            |
| `duration_ms` | classifier time, nil on caller-decided routes                |
| `classifier`  | `{ with:, model: }`, or nil when no backend was called       |

`route.error` is the exception a failed classifier raised, and `route.inputs` the router's inputs; `route.mode(chat:, **options)` is `mode_class.new(chat:, inputs:, **options)`. `to_h` is the fields above with string keys, minus `mode_class`; `Decision#to_h` has string keys and omits `probabilities` when nil.

### Outcomes

The route is decided by the first rule that applies:

| Situation                                     | decided_by     | reason                                 |
|-----------------------------------------------|----------------|----------------------------------------|
| `force(name)`                                 | `"caller"`     | `"Mode requested by caller"`           |
| only the fallback is available                | `"fallback"`   | `"No other mode available"`            |
| classifier raised, or violated the contract   | `"fallback"`   | `"Classifier failed: <class>: <message>"` |
| decision names an unknown or unavailable mode | `"fallback"`   | `"Unknown mode <name>"`                |
| threshold on, confidence nil                  | `"fallback"`   | `"Confidence not scored"`              |
| threshold on, confidence below it             | `"fallback"`   | `"Below confidence threshold"`         |
| otherwise                                     | `"classifier"` | the decision's reason                  |

`<message>` is the first line of the exception's message, cut at 200 characters, so a provider's error body reaches the log.

### Errors

`Router.new` raises `DeclarationError` for any problem in the declaration and says which. `force` raises `UnknownMode`, a `KeyError`. A classifier that raised, or broke the contract (a `ContractError`), does not fail the turn: the route falls back and the exception is on `route.error`. To fail instead, raise from `on_error`; whatever the handler raises escapes `call`. An exception from an `instructions` block or template is a declaration bug and escapes `call` as well.

## Examples

`examples/` holds three runnable programs that double as the integration tests: contextual routing through `instructions`, a tool mode followed by a clarification mode on one chat, and a custom classifier whose low-confidence decision falls back with a full trace.

```
bundle exec ruby examples/contextual_routing.rb
bundle exec rake
```

## License

MIT. See [LICENSE.txt](LICENSE.txt).
