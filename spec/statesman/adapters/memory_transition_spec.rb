# frozen_string_literal: true

require "statesman/adapters/memory_transition"

describe Statesman::Adapters::MemoryTransition do
  describe "#initialize" do
    let(:from) { :n }
    let(:to) { :y }
    let(:sort_key) { 0 }
    let(:create) { described_class.new(from, to, sort_key) }

    specify { expect(create.from_state).to equal(from) }
    specify { expect(create.to_state).to equal(to) }
    specify { expect(create.created_at).to be_a(Time) }
    specify { expect(create.updated_at).to be_a(Time) }
    specify { expect(create.sort_key).to be(sort_key) }

    context "with metadata passed" do
      let(:metadata) { { some: :hash } }
      let(:create) { described_class.new(from, to, sort_key, metadata) }

      specify { expect(create.metadata).to eq(metadata) }
    end
  end
end
