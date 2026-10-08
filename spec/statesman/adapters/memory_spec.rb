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

  # Drives .bulk_create directly, with a real Machine class/instance per item — the
  # same combination BulkTransition#write_batch itself builds (see its `payload`),
  # since `item[:adapter].observer` has to be a real Machine for before/after/
  # after_commit to dispatch to anything. Unit-level: see
  # spec/statesman/bulk_transition_spec.rb's ".call" block for the end-to-end,
  # equivalence-with-a-loop-of-#transition_to! coverage through the real
  # Machine/BulkTransition/Adapters::Memory stack together.
  describe ".bulk_create" do
    subject(:result) do
      described_class.bulk_create(items, from: "pending", to: "approved", on_failure: on_failure,
                                         skip_before_callbacks: skip_before_callbacks,
                                         skip_after_callbacks: skip_after_callbacks,
                                         skip_after_commit_callbacks: skip_after_commit_callbacks)
    end

    let(:machine_class) do
      Class.new do
        include Statesman::Machine

        def self.name
          "MyBulkStateMachine"
        end

        state :pending, initial: true
        state :approved
        transition from: :pending, to: :approved
      end
    end
    let(:model_class) { Class.new { attr_accessor :current_state } }
    let(:object_a) { model_class.new }
    let(:object_b) { model_class.new }
    let(:machine_a) { machine_class.new(object_a) }
    let(:machine_b) { machine_class.new(object_b) }
    let(:items) { [item_for(machine_a), item_for(machine_b)] }
    let(:captured) { {} }
    let(:calls) { [] }
    let(:skip_before_callbacks) { false }
    let(:skip_after_callbacks) { false }
    let(:skip_after_commit_callbacks) { false }
    let(:on_failure) { :collect }

    def item_for(machine, metadata: {})
      { object: machine.object, adapter: machine.storage_adapter, metadata: metadata }
    end

    before do
      recorder = calls
      store = captured
      machine_class.before_transition { |object, _transition| recorder << [:before, object] }
      machine_class.after_transition { |object, _transition| recorder << [:after, object] }
      machine_class.after_transition { |object, transition| store[object] = transition }
      machine_class.after_transition(after_commit: true) { |object, _transition| recorder << [:after_commit, object] }
    end

    context "with no items" do
      let(:items) { [] }

      it "returns an empty Result instead of raising" do
        expect(result.successful).to eq([])
        expect(result.failed).to eq([])
        expect(result.success?).to be(true)
      end
    end

    it "persists a transition for every object" do
      result
      expect(captured[object_a].to_state).to eq("approved")
      expect(captured[object_b].to_state).to eq("approved")
    end

    it "returns every object as successful, with no failures" do
      expect(result.successful).to eq([object_a, object_b])
      expect(result.failed).to eq([])
    end

    it "applies the given metadata" do
      items = [item_for(machine_a, metadata: { "k" => "v" }), item_for(machine_b, metadata: { "k" => "v" })]
      described_class.bulk_create(items, from: "pending", to: "approved")

      expect(captured[object_a].metadata).to eq({ "k" => "v" })
      expect(captured[object_b].metadata).to eq({ "k" => "v" })
    end

    context "when an item carries its own metadata" do
      let(:items) { [item_for(machine_a, metadata: { "k" => "override", "extra" => 1 }), item_for(machine_b)] }

      it "applies it to that item's transition only" do
        result
        expect(captured[object_a].metadata).to eq({ "k" => "override", "extra" => 1 })
        expect(captured[object_b].metadata).to eq({})
      end
    end

    # Each item runs build -> before -> persist -> after -> after_commit in turn,
    # uninterrupted, before moving to the next — Memory has no real transactions and
    # nothing to batch, so there's no reason to group all of one phase across every
    # item the way Adapters::ActiveRecord::BulkCreate does (see its own docs for why
    # *that* needs a different shape).
    it "runs before, persist, after, then after_commit for one object before moving to the next" do
      result
      expect(calls).to eq(
        [
          [:before, object_a],
          [:after, object_a],
          [:after_commit, object_a],
          [:before, object_b],
          [:after, object_b],
          [:after_commit, object_b],
        ],
      )
    end

    context "when a before callback raises for one item" do
      before do
        machine_class.before_transition { |object, _transition| raise StandardError, "boom" if object == object_a }
      end

      it "collects the failure and still persists the other item" do
        expect(result.successful).to eq([object_b])
        expect(result.failed.map(&:object)).to eq([object_a])
      end

      it "records the failure with reason :before_callback and the raised error" do
        expect(result.failed.first.reason).to eq(:before_callback)
        expect(result.failed.first.error.message).to eq("boom")
      end

      context "with on_failure: :raise" do
        let(:on_failure) { :raise }

        it "raises instead of collecting the failure" do
          expect { result }.to raise_error(StandardError, "boom")
        end
      end
    end

    context "when one item fails to persist" do
      before do
        allow(machine_a.storage_adapter).to receive(:persist).and_raise(StandardError.new("boom"))
      end

      it "still persists the other item" do
        expect(result.successful).to eq([object_b])
      end

      it "reports the failing item as a conflict" do
        expect(result.failed.map(&:object)).to eq([object_a])
        expect(result.failed.first.reason).to eq(:conflict)
      end

      it "never dispatches after/after_commit for the item that failed to persist" do
        result
        expect(calls).to eq([[:before, object_a], [:before, object_b], [:after, object_b], [:after_commit, object_b]])
      end
    end

    context "when building a transition raises for one item" do
      before do
        allow(machine_a.storage_adapter).to receive(:build_transition).and_raise(StandardError.new("boom"))
      end

      it "collects the failure and still persists the other item" do
        expect(result.successful).to eq([object_b])
        expect(result.failed.map(&:object)).to eq([object_a])
      end

      it "records the failure with reason :build_transition, not :before_callback" do
        expect(result.failed.first.reason).to eq(:build_transition)
        expect(result.failed.first.error.message).to eq("boom")
      end

      it "never runs before/after callbacks for the item whose build failed" do
        result
        expect(calls).to eq([[:before, object_b], [:after, object_b], [:after_commit, object_b]])
      end
    end

    context "when an after callback raises for one item" do
      before do
        machine_class.after_transition { |object, _transition| raise StandardError, "boom" if object == object_a }
      end

      it "still reports the item as successful, since the transition did persist" do
        expect(result.successful).to eq([object_a, object_b])
      end

      it "also records the failure, with reason :after_callback" do
        expect(result.failed.map(&:object)).to eq([object_a])
        expect(result.failed.first.reason).to eq(:after_callback)
        expect(result.failed.first.error.message).to eq("boom")
      end

      # Consistent with Adapters::ActiveRecord's decoupling (see BulkCreate's docs):
      # after_commit's guarantee is "the transition is durable", not "and `after` also
      # succeeded" — object_a's own after_commit still fires even though its after
      # callback raised.
      it "still dispatches after_commit for the item whose own after callback raised" do
        result
        expect(calls).to include([:after_commit, object_a])
      end

      it "still dispatches after/after_commit for the other item" do
        result
        expect(calls).to include([:after_commit, object_b])
      end

      context "with on_failure: :raise" do
        let(:on_failure) { :raise }

        it "raises instead of collecting the failure" do
          expect { result }.to raise_error(StandardError, "boom")
        end
      end
    end

    context "with skip_before_callbacks: true" do
      let(:skip_before_callbacks) { true }

      it "skips only before" do
        result
        expect(calls.map(&:first)).to eq(%i[after after_commit after after_commit])
      end
    end

    context "with skip_after_callbacks: true" do
      let(:skip_after_callbacks) { true }

      it "skips only after" do
        result
        expect(calls.map(&:first)).to eq(%i[before after_commit before after_commit])
      end
    end

    context "with skip_after_commit_callbacks: true" do
      let(:skip_after_commit_callbacks) { true }

      it "skips only after_commit" do
        result
        expect(calls.map(&:first)).to eq(%i[before after before after])
      end
    end

    context "with all three skip options set" do
      let(:skip_before_callbacks) { true }
      let(:skip_after_callbacks) { true }
      let(:skip_after_commit_callbacks) { true }

      it "fires no before/after/after_commit callbacks, but still persists" do
        expect(result.successful).to eq([object_a, object_b])
        expect(calls).to eq([])
      end
    end
  end
end
