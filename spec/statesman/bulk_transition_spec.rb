# frozen_string_literal: true

# Unit-level: builds machines directly and keeps a reference to them, so — unlike
# Machine.bulk_transition_to! callers (see machine_spec.rb's ".bulk_transition_to!" for
# the end-to-end specs) — it can verify persistence by re-querying each machine's own
# storage_adapter, no callback-capturing needed.
describe Statesman::BulkTransition do
  subject(:writer) do
    described_class.new("approved", metadata: { "k" => "v" }, skip_before_callbacks: skip_before_callbacks,
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
  let(:machines) { [machine_a, machine_b] }
  let(:calls) { [] }
  let(:skip_before_callbacks) { false }
  let(:skip_after_callbacks) { false }
  let(:skip_after_commit_callbacks) { false }

  before do
    recorder = calls
    machine_class.before_transition { |object, _transition| recorder << [:before, object] }
    machine_class.after_transition { |object, _transition| recorder << [:after, object] }
    machine_class.after_transition(after_commit: true) { |object, _transition| recorder << [:after_commit, object] }
  end

  describe "#persist" do
    subject(:result) { writer.persist("pending", machines) }

    context "with no machines" do
      let(:machines) { [] }

      it "returns an empty Result instead of raising" do
        expect(result.successful).to eq([])
        expect(result.failed).to eq([])
        expect(result.success?).to be(true)
      end
    end

    it "persists a transition for every machine, via each one's own storage_adapter" do
      result
      expect(machine_a.storage_adapter.history.map(&:to_state)).to eq(["approved"])
      expect(machine_b.storage_adapter.history.map(&:to_state)).to eq(["approved"])
    end

    it "returns every object as successful, with no failures" do
      expect(result.successful).to eq([object_a, object_b])
      expect(result.failed).to eq([])
    end

    it "applies the given metadata to every transition" do
      result
      expect(machine_a.storage_adapter.history.first.metadata).to eq({ "k" => "v" })
      expect(machine_b.storage_adapter.history.first.metadata).to eq({ "k" => "v" })
    end

    it "runs before, then after, then after_commit, once per machine" do
      result
      expect(calls).to eq(
        [
          [:before, object_a],
          [:before, object_b],
          [:after, object_a],
          [:after_commit, object_a],
          [:after, object_b],
          [:after_commit, object_b],
        ],
      )
    end

    context "when items don't all share the same adapter class" do
      let(:other_adapter_class) { Class.new(Statesman::Adapters::Memory) }
      let(:other_adapter) { other_adapter_class.new(Statesman::Adapters::MemoryTransition, object_b, machine_b) }

      before { allow(machine_b).to receive(:storage_adapter).and_return(other_adapter) }

      it "raises instead of silently persisting some items through the wrong adapter" do
        expect { result }.to raise_error(ArgumentError, /same storage adapter/)
      end
    end

    context "when one item fails to persist" do
      before { allow(machine_a.storage_adapter).to receive(:persist).and_raise(StandardError.new("boom")) }

      it "still persists the other item" do
        expect(result.successful).to eq([object_b])
      end

      it "reports the failing item as a conflict" do
        expect(result.failed.map(&:object)).to eq([object_a])
        expect(result.failed.first.reason).to eq(:conflict)
      end

      it "dispatches after/after_commit for the surviving item only" do
        result
        expect(calls).to eq([[:before, object_a], [:before, object_b], [:after, object_b], [:after_commit, object_b]])
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
        expect(calls.map(&:first)).to eq(%i[before before after_commit after_commit])
      end
    end

    context "with skip_after_commit_callbacks: true" do
      let(:skip_after_commit_callbacks) { true }

      it "skips only after_commit" do
        result
        expect(calls.map(&:first)).to eq(%i[before before after after])
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
