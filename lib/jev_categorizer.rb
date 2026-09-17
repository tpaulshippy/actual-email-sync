# frozen_string_literal: true

require_relative 'actual_categories'
# Categorizes email transactions into Actual Budget categories using
# TypeSafe's Jev (a System One model) via the ruby_llm-typesafe provider.
#
# Design (per https://typesafe.ai/blog/introducing-system-one-models-and-jev):
# Jev does not generate text. We send one piece of state (the transaction as
# JSON) plus a batch of typed questions, and get back calibrated
# probabilities. Here that is a single Choice question whose options are the
# live Actual categories — so Jev *cannot* hallucinate a category that does
# not exist in Actual.
#
#   categorizer = JevCategorizer.new(categories: ActualCategories.spending)
#   result = categorizer.categorize_transaction(
#     'merchant' => 'CHIPOTLE 0658', 'amount' => -75.43,
#     'email_subject' => '...', 'source' => 'fidelity_card_posted'
#   )
#   result[:category_id]  # => Actual UUID, or nil when below threshold
#
# Requires TYPESAFE_API_KEY. See ruby_llm-typesafe:
# https://github.com/kieranklaassen/ruby_llm-typesafe
class JevCategorizer
  DEFAULT_MODEL = 'jev-latest'
  QUESTION_ID = :category

  attr_reader :categories, :model, :min_confidence, :criteria

  # categories: array of { id:, name:, group:, is_income: } from ActualCategories.
  # chat_factory: injectable for tests; receives (schema) and must respond to
  #   #ask(state_json) with an object responding to #parsed.
  def initialize(categories:, model: DEFAULT_MODEL, min_confidence: 0.0, chat_factory: nil)
    if categories.nil? || categories.empty?
      raise ArgumentError,
            'categories must not be empty (load them from Actual via ActualCategories)'
    end

    @categories = categories
    @model = model || DEFAULT_MODEL
    @min_confidence = min_confidence.to_f
    @criteria = ActualCategories.to_criteria(categories)
    @chat_factory = chat_factory
  end

  def instructions
    'Which Actual Budget category best fits this bank transaction? ' \
      'Classify by the merchant and what was purchased, not by the email wording.'
  end

  # Build the TypeSafe schema (the request). Requires the provider gem.
  def build_schema
    require 'ruby_llm-typesafe'
    RubyLLM::Providers::TypeSafe::Schema.new do |s|
      s.choice JevCategorizer::QUESTION_ID,
               instructions: instructions,
               criteria: criteria
    end
  end

  # Categorize one transaction hash. Returns:
  # { category_id:, category_name:, choice:, confidence:, probabilities: }
  # category_id/name are nil when Jev's choice is unknown or confidence is
  # below min_confidence (caller should leave the transaction uncategorized
  # rather than file it wrongly).
  def categorize_transaction(txn)
    categorize(state_for(txn))
  end

  # Categorize a pre-built state (Hash serialized to JSON, or String).
  def categorize(state)
    answer = parsed_answer(chat.ask(state_to_json(state)))
    build_result(answer)
  end

  # The state sent to Jev: the transaction record as JSON. State (not chat
  # history) is what System One models decide over, so keep it dense.
  def state_for(txn)
    {
      merchant: txn['merchant'] || txn[:merchant],
      amount: txn['amount'] || txn[:amount],
      date: txn['transaction_date'] || txn[:transaction_date],
      email_subject: txn['email_subject'] || txn[:email_subject],
      source: txn['source'] || txn[:source]
    }.compact
  end

  private

  def parsed_answer(response)
    answer = response.parsed[QUESTION_ID.to_s] || response.parsed[QUESTION_ID]
    raise "Unexpected Jev response shape: #{response.parsed.inspect}" unless answer && answer['choice']

    answer
  end

  def build_result(answer)
    choice = answer['choice']
    confidence = answer['confidence'].to_f
    probabilities = answer['probabilities'] || {}
    category = ActualCategories.find_by_choice(categories, choice)
    return uncategorized(choice, confidence, probabilities) if category.nil? || confidence < min_confidence

    { category_id: category[:id], category_name: category[:name],
      choice: choice, confidence: confidence, probabilities: probabilities }
  end

  def uncategorized(choice, confidence, probabilities)
    { category_id: nil, category_name: nil, choice: choice,
      confidence: confidence, probabilities: probabilities }
  end

  def state_to_json(state)
    state.is_a?(String) ? state : require_json(state)
  end

  def require_json(state)
    require 'json'
    JSON.generate(state)
  end

  def chat
    return @chat_factory.call(build_schema_for_factory) if @chat_factory

    require 'ruby_llm-typesafe'
    unless ENV['TYPESAFE_API_KEY'] && !ENV['TYPESAFE_API_KEY'].empty?
      raise 'Set TYPESAFE_API_KEY (from https://console.typesafe.ai) to categorize with Jev.'
    end

    RubyLLM.configure do |config|
      config.typesafe_api_key = ENV['TYPESAFE_API_KEY']
    end
    RubyLLM.chat(model: model, provider: :typesafe).with_schema(build_schema)
  end

  # When a test factory is injected, it only needs the criteria, not the gem.
  def build_schema_for_factory
    { question: QUESTION_ID, instructions: instructions, criteria: criteria }
  end
end
