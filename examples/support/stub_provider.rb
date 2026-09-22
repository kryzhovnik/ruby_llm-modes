# frozen_string_literal: true

# Replaces the provider request of one real RubyLLM::Chat. Everything else
# in the chat (messages, schema, tools, thinking) stays real; only the
# network call is stubbed, on that chat's own provider instance.
module StubProvider
  Request = Struct.new(:messages, :options)

  # Stubs +chat+. The block receives the outgoing messages and the request
  # options (schema:, tools:, thinking:, ...) and returns the assistant's
  # text. Returns the list of requests made, filled in as they happen.
  def self.stub(chat, &responder)
    requests = []
    chat.provider.define_singleton_method(:complete) do |messages, **options, &_stream|
      requests << Request.new(messages, options)
      content = responder.call(messages, **options)
      RubyLLM::Message.new(role: :assistant, content: content, model: options[:model]&.id)
    end
    requests
  end

  # A chat_factory for the :chat backend whose provider always answers with
  # the given selection. The last request is kept on +requests+.
  class ChatFactory
    attr_reader :requests, :calls

    def initialize(mode:, confidence: 0.9, reason: "stubbed")
      @selection = { mode: mode, confidence: confidence, reason: reason }
      @requests = []
      @calls = []
    end

    def call(model:)
      @calls << { model: model }
      RubyLLM.chat(model: model).tap do |chat|
        StubProvider.stub(chat) do |_messages, **options|
          @requests << options.merge(messages: chat.messages.dup)
          JSON.generate(@selection)
        end
      end
    end

    def last_request
      @requests.last
    end

    def system_prompt
      last_request[:messages].find { |message| message.role == :system }&.content
    end
  end
end
