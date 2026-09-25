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

  describe ".bulk_create" do
    subject(:result) { described_class.bulk_create(items, after_persist: after_persist, after_commit: after_commit) }

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
    let(:after_persist) { nil }
    let(:after_commit) { nil }

    it "reports every object as transitioned, with no failures" do
      expect(result.transitioned).to eq([object_a, object_b])
      expect(result.failed).to eq([])
      expect(result.success?).to be(true)
    end

    it "persists each item's transition via its own adapter" do
      result
      expect(adapter_a.history).to eq([transition_a])
      expect(adapter_b.history).to eq([transition_b])
    end

    context "with after_persist and after_commit callbacks" do
      let(:calls) { [] }
      let(:after_persist) { ->(object, transition) { calls << [:after_persist, object, transition] } }
      let(:after_commit) { ->(object, transition) { calls << [:after_commit, object, transition] } }

      it "invokes both callbacks once per item, after persisting it" do
        result
        expect(calls).to eq(
          [
            [:after_persist, object_a, transition_a],
            [:after_commit, object_a, transition_a],
            [:after_persist, object_b, transition_b],
            [:after_commit, object_b, transition_b],
          ],
        )
      end
    end

    context "without callbacks" do
      it "does not require after_persist/after_commit to be passed" do
        expect { described_class.bulk_create(items) }.to_not raise_error
      end
    end
  end
end
