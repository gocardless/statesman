# frozen_string_literal: true

require "statesman/adapters/shared_examples"
require "statesman/adapters/memory_transition"

describe Statesman::Adapters::Memory do
  let(:model) { Class.new { attr_accessor :current_state }.new }

  it_behaves_like "an adapter", described_class,
                  Statesman::Adapters::MemoryTransition

  describe "#build_transition" do
    subject(:transition) { adapter.build_transition("x", "y", { "some" => "hash" }) }

    let(:observer) { instance_double(Statesman::Machine, execute: nil) }
    let(:adapter) { described_class.new(Statesman::Adapters::MemoryTransition, Object.new, observer) }

    it { is_expected.to be_a(Statesman::Adapters::MemoryTransition) }
    its(:from_state) { is_expected.to eq("x") }
    its(:to_state) { is_expected.to eq("y") }
    its(:metadata) { is_expected.to eq({ "some" => "hash" }) }

    it "does not touch history or fire any callbacks" do
      expect(observer).to_not receive(:execute)
      expect { transition }.to_not change(adapter, :history)
    end

    context "with a previous transition" do
      before { adapter.create("w", "x") }

      its(:sort_key) { is_expected.to be(20) }
    end
  end

  describe "#persist" do
    subject(:persist) { adapter.persist(transition) }

    let(:observer) { instance_double(Statesman::Machine, execute: nil) }
    let(:adapter) { described_class.new(Statesman::Adapters::MemoryTransition, Object.new, observer) }
    let(:transition) { adapter.build_transition("x", "y") }

    it { expect { persist }.to change(adapter.history, :count).by(1) }
    it { is_expected.to eq(transition) }

    it "fires no callbacks" do
      expect(observer).to_not receive(:execute)
      persist
    end
  end

  describe ".build_transitions" do
    subject(:build_result) { described_class.build_transitions(items) }

    let(:observer) { instance_double(Statesman::Machine, execute: nil) }
    let(:object_a) { Object.new }
    let(:object_b) { Object.new }
    let(:adapter_a) do
      described_class.new(Statesman::Adapters::MemoryTransition, object_a, observer)
    end
    let(:adapter_b) do
      described_class.new(Statesman::Adapters::MemoryTransition, object_b, observer)
    end
    let(:items) do
      [
        { object: object_a, adapter: adapter_a, from: "x", to: "y", metadata: { "a" => 1 } },
        { object: object_b, adapter: adapter_b, from: "x", to: "y", metadata: { "b" => 2 } },
      ]
    end

    it "returns a built, unsaved transition entry for every item" do
      entries, failed = build_result

      expect(failed).to eq([])
      expect(entries).to contain_exactly(
        { object: object_a, adapter: adapter_a, transition: having_attributes(from_state: "x", to_state: "y",
                                                                              metadata: { "a" => 1 }) },
        { object: object_b, adapter: adapter_b, transition: having_attributes(from_state: "x", to_state: "y",
                                                                              metadata: { "b" => 2 }) },
      )
    end

    it "does not persist anything" do
      build_result
      expect(adapter_a.history).to eq([])
      expect(adapter_b.history).to eq([])
    end

    context "when building an item's transition raises" do
      let(:error) { StandardError.new("boom") }

      before { allow(adapter_a).to receive(:build_transition).and_raise(error) }

      it "still builds the other item" do
        entries, = build_result
        expect(entries.map { |entry| entry[:object] }).to eq([object_b])
      end

      it "tags the failure as :build_transition, with the original error" do
        _, failed = build_result
        expect(failed.map(&:object)).to eq([object_a])
        expect(failed.first.reason).to eq(:build_transition)
        expect(failed.first.error).to eq(error)
      end
    end
  end

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
    let(:transition_a) { adapter_a.build_transition("x", "y") }
    let(:transition_b) { adapter_b.build_transition("x", "y") }
    let(:items) do
      [
        { object: object_a, adapter: adapter_a, transition: transition_a },
        { object: object_b, adapter: adapter_b, transition: transition_b },
      ]
    end

    it "reports every object as successful, with no failures" do
      expect(result.successful).to eq([object_a, object_b])
      expect(result.failed).to eq([])
      expect(result.success?).to be(true)
    end

    it "persists each item's transition via its own adapter" do
      result
      expect(adapter_a.history).to eq([transition_a])
      expect(adapter_b.history).to eq([transition_b])
    end

    it "fires no callbacks" do
      expect(observer).to_not receive(:execute)
      result
    end

    context "when persisting an item raises" do
      let(:error) { StandardError.new("boom") }

      before { allow(adapter_a).to receive(:persist).and_raise(error) }

      it "reports the other items as successful" do
        expect(result.successful).to eq([object_b])
      end

      it "reports the failing item's object in failed" do
        expect(result.failed.map(&:object)).to eq([object_a])
      end

      it "tags the failure as a conflict, with the original error" do
        expect(result.failed.first.reason).to eq(:conflict)
        expect(result.failed.first.error).to eq(error)
      end

      it "still persists the other items" do
        result
        expect(adapter_b.history).to eq([transition_b])
      end

      it "reports a partial status" do
        expect(result.status).to eq(:partial)
        expect(result.success?).to be(false)
      end
    end
  end
end
