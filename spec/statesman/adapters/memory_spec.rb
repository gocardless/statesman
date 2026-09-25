# frozen_string_literal: true

require "statesman/adapters/shared_examples"
require "statesman/adapters/memory_transition"

describe Statesman::Adapters::Memory do
  let(:model) { Class.new { attr_accessor :current_state }.new }

  it_behaves_like "an adapter", described_class,
                  Statesman::Adapters::MemoryTransition

  describe ".bulk_create" do
    subject(:result) { described_class.bulk_create(items) }

    let(:observer) { instance_double(Statesman::Machine, execute: nil) }
    let(:object_a) { Object.new }
    let(:object_b) { Object.new }
    let(:adapter_a) do
      described_class.new(Statesman::Adapters::MemoryTransition, object_a, observer)
    end
    let(:adapter_b) do
      described_class.new(Statesman::Adapters::MemoryTransition, object_b, observer)
    end

    context "when every item succeeds" do
      let(:items) do
        [
          { object: object_a, adapter: adapter_a, from: "x", to: "y", metadata: {} },
          { object: object_b, adapter: adapter_b, from: "x", to: "y", metadata: {} },
        ]
      end

      it "reports every object as transitioned, with no failures" do
        expect(result.transitioned).to eq([object_a, object_b])
        expect(result.failed).to eq([])
        expect(result.success?).to be(true)
      end

      it "actually writes a transition via each object's own adapter" do
        result
        expect(adapter_a.history.map(&:to_state)).to eq(["y"])
        expect(adapter_b.history.map(&:to_state)).to eq(["y"])
      end
    end

    context "when an item's adapter raises GuardFailedError" do
      let(:failing_adapter) { instance_double(described_class) }
      let(:items) do
        [
          { object: object_a, adapter: adapter_a, from: "x", to: "y", metadata: {} },
          { object: object_b, adapter: failing_adapter, from: "x", to: "y", metadata: {} },
        ]
      end

      before do
        allow(failing_adapter).to receive(:create).
          and_raise(Statesman::GuardFailedError.new("x", "y", -> {}))
      end

      it "excludes the failing object from transitioned" do
        expect(result.transitioned).to eq([object_a])
      end

      its(:failed) do
        is_expected.to contain_exactly(
          having_attributes(object: object_b, reason: :guard, error: an_instance_of(Statesman::GuardFailedError)),
        )
      end
    end

    context "when an item's adapter raises TransitionFailedError" do
      let(:failing_adapter) { instance_double(described_class) }
      let(:items) do
        [{ object: object_a, adapter: failing_adapter, from: "x", to: "y", metadata: {} }]
      end

      before do
        allow(failing_adapter).to receive(:create).
          and_raise(Statesman::TransitionFailedError.new("x", "y"))
      end

      its(:failed) { is_expected.to contain_exactly(having_attributes(reason: :invalid_current_state)) }
    end

    context "when an item's adapter raises TransitionConflictError" do
      let(:failing_adapter) { instance_double(described_class) }
      let(:items) do
        [{ object: object_a, adapter: failing_adapter, from: "x", to: "y", metadata: {} }]
      end

      before do
        allow(failing_adapter).to receive(:create).
          and_raise(Statesman::TransitionConflictError)
      end

      its(:failed) { is_expected.to contain_exactly(having_attributes(reason: :conflict)) }
    end

    context "when an item's adapter raises an unrecognised error" do
      let(:failing_adapter) { instance_double(described_class) }
      let(:items) do
        [{ object: object_a, adapter: failing_adapter, from: "x", to: "y", metadata: {} }]
      end

      before { allow(failing_adapter).to receive(:create).and_raise(RuntimeError, "boom") }

      it "is not swallowed into the result" do
        expect { result }.to raise_error(RuntimeError, "boom")
      end
    end
  end
end
