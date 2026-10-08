# frozen_string_literal: true

# Unit-level: builds machines directly and keeps a reference to them, so it can verify
# persistence by re-querying each machine's own storage_adapter, no callback-capturing
# needed. See the ".call" describe block below for the end-to-end specs covering the
# public entry point (validation, batching, grouping).
describe Statesman::BulkTransition do
  describe "#persist" do
    subject(:result) { writer.persist("pending", machines) }

    let(:writer) do
      described_class.new("approved", metadata: { "k" => "v" }, skip_before_callbacks: skip_before_callbacks,
                                      skip_after_callbacks: skip_after_callbacks,
                                      skip_after_commit_callbacks: skip_after_commit_callbacks,
                                      on_failure: on_failure)
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
    let(:on_failure) { :collect }

    before do
      recorder = calls
      machine_class.before_transition { |object, _transition| recorder << [:before, object] }
      machine_class.after_transition { |object, _transition| recorder << [:after, object] }
      machine_class.after_transition(after_commit: true) { |object, _transition| recorder << [:after_commit, object] }
    end

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

      it "raises before building any transition or running any before callback" do
        expect { result }.to raise_error(ArgumentError)
        expect(calls).to eq([])
      end
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

    it "gives each item its own metadata object, so one item's before callback can't " \
       "mutate another item's metadata" do
      machine_class.before_transition { |object, transition| transition.metadata.delete("k") if object == object_a }

      result

      expect(machine_a.storage_adapter.history.first.metadata).to eq({})
      expect(machine_b.storage_adapter.history.first.metadata).to eq({ "k" => "v" })
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

    context "with on_failure: :raise and a custom conflict_retry_attempts" do
      let(:writer) { described_class.new("approved", on_failure: :raise, conflict_retry_attempts: 5) }

      it "threads both options through to the adapter's bulk_create" do
        expect(Statesman::Adapters::Memory).to receive(:bulk_create).
          with(anything, from: "pending", after: anything, after_commit: anything,
                         on_failure: :raise, conflict_retry_attempts: 5).
          and_call_original
        result
      end
    end
  end

  # NOTE on verification strategy: the memory adapter's history is scoped to a single
  # Machine instance's lifetime (Adapters::Memory#initialize always starts `@history =
  # []`), not to the parent object — this is pre-existing and unrelated to bulk
  # transitions (a fresh `machine_class.new(model)` never sees a transition written by a
  # *different* instance for the same model, with or without BulkTransition.call — this
  # was confirmed on unmodified code too: `klass.new(m).transition_to!(:y)` followed by a
  # fresh `klass.new(m).current_state` returns "x", not "y"). .call itself only ever
  # receives one machine per object per call and uses it consistently for that call, so
  # this doesn't affect correctness — but it does mean these specs can't verify results by
  # re-instantiating a fresh machine afterward. Instead they rely on
  # `result.successful`/`result.failed` (built during the call itself), a real
  # `after_transition` callback to capture written transitions where deeper properties
  # matter, and `allow_any_instance_of` (already used elsewhere in this file) on the rare
  # occasion a test needs objects starting from different states within one call.
  describe ".call" do
    let(:machine_class) do
      Class.new do
        include Statesman::Machine

        def self.name
          "MyBulkStateMachine"
        end

        state :pending, initial: true
        state :processing
        state :completed
        transition from: :pending, to: :processing
        transition from: :pending, to: :completed
        transition from: :processing, to: :completed
      end
    end

    let(:model_class) { Class.new { attr_accessor :current_state } }
    let(:captured) { {} }

    def build_objects(count)
      Array.new(count) { model_class.new }
    end

    def build_machines(objects)
      objects.map { |object| machine_class.new(object) }
    end

    # Registers a real Statesman `after` callback to capture the transition actually
    # written for each object, keyed by object. Does not fire under skip_after_callbacks.
    def capture_transitions!
      store = captured
      machine_class.after_transition { |object, transition| store[object] = transition }
    end

    describe "end-to-end on the memory adapter" do
      subject(:result) { described_class.call(machines, :processing) }

      let(:objects) { build_objects(3) }
      let(:machines) { build_machines(objects) }

      before { capture_transitions! }

      it "transitions every object and reports no failures" do
        expect(result.successful).to match_array(objects)
        expect(result.failed).to eq([])
        expect(result.success?).to be(true)
      end

      it "actually writes each object's transition to state processing" do
        result
        objects.each { |object| expect(captured[object].to_state).to eq("processing") }
      end

      it "applies the given metadata to every transition in the batch" do
        described_class.call(machines, :processing, metadata: { "batch_id" => 42 })
        objects.each { |object| expect(captured[object].metadata).to eq({ "batch_id" => 42 }) }
      end

      context "with a mixed batch (some succeed, one is guarded, one has a bad edge)" do
        let(:good_object) { model_class.new }
        let(:guarded_object) { model_class.new }
        let(:invalid_object) { model_class.new }
        let(:objects) { [good_object, guarded_object, invalid_object] }

        before do
          machine_class.guard_transition(from: :pending, to: :processing) { |object, *| object != guarded_object }

          # invalid_object needs a *different* starting state than the other two so that
          # :processing is not a declared successor of it; see the file-level NOTE on why
          # this is stubbed rather than set up via a real prior transition.
          allow_any_instance_of(machine_class).to receive(:current_state) do |instance|
            instance.object == invalid_object ? "completed" : "pending"
          end
        end

        it "partitions successful vs failed correctly" do
          result = described_class.call(machines, :processing)

          expect(result.successful).to eq([good_object])
          expect(result.failed).to contain_exactly(
            having_attributes(object: guarded_object, reason: :guard),
            having_attributes(object: invalid_object, reason: :invalid_current_state),
          )
        end
      end
    end

    describe "a machine that's a subclass of another passed in the same batch" do
      let(:sub_class) do
        Class.new(machine_class) do
          def self.name
            "MyBulkSubStateMachine"
          end

          state :pending, initial: true
          state :processing
          transition from: :pending, to: :processing
          guard_transition(from: :pending, to: :processing) { false }
        end
      end

      let(:object) { model_class.new }
      let(:sub_machine) { sub_class.new(object) }

      it "validates against the subclass's own guards, not the base class's" do
        result = described_class.call([sub_machine], :processing)

        expect(result.successful).to eq([])
        expect(result.failed.first.reason).to eq(:guard)
      end

      it "groups each class's machines separately and merges the results, when mixed in one batch" do
        base_machine = machine_class.new(model_class.new)

        result = described_class.call([base_machine, sub_machine], :processing)

        expect(result.successful).to eq([base_machine.object])
        expect(result.failed).to contain_exactly(having_attributes(object: sub_machine.object, reason: :guard))
      end
    end

    describe "duplicate objects" do
      let(:object) { model_class.new }

      it "raises instead of persisting the same object twice" do
        duplicated_machines = [machine_class.new(object), machine_class.new(object)]

        expect { described_class.call(duplicated_machines, :processing) }.
          to raise_error(ArgumentError, /duplicate objects/)
      end

      it "does not raise for the same object run through two different, unrelated machine classes" do
        other_machine_class = Class.new do
          include Statesman::Machine

          def self.name
            "MyOtherBulkStateMachine"
          end

          state :pending, initial: true
          state :processing
          transition from: :pending, to: :processing
        end

        machines = [machine_class.new(object), other_machine_class.new(object)]

        expect(described_class.call(machines, :processing).successful).to eq([object, object])
      end
    end

    describe "equivalence with a loop of #transition_to!" do
      before { capture_transitions! }

      it "produces the same final transition shape" do
        looped = build_objects(2)
        bulked = build_objects(2)

        looped.each { |object| machine_class.new(object).transition_to!(:processing, { "k" => "v" }) }
        described_class.call(build_machines(bulked), :processing, metadata: { "k" => "v" })

        looped.zip(bulked).each do |looped_object, bulked_object|
          looped_transition = captured[looped_object]
          bulked_transition = captured[bulked_object]

          expect(bulked_transition).to have_attributes(
            from_state: looped_transition.from_state,
            to_state: looped_transition.to_state,
            sort_key: looped_transition.sort_key,
            metadata: looped_transition.metadata,
          )
        end
      end
    end

    describe "successor validation" do
      subject(:result) do
        described_class.call([machine_class.new(object)], :pending, skip_guards: true,
                                                                    skip_before_callbacks: true,
                                                                    skip_after_callbacks: true,
                                                                    skip_after_commit_callbacks: true)
      end

      let(:object) { model_class.new }

      it "is enforced even with every skip option set" do
        # pending has no self-edge declared, so this must fail structurally regardless of
        # the skips.
        expect(result.successful).to eq([])
        expect(result.failed.first.reason).to eq(:invalid_current_state)
      end
    end

    describe "after_guard_failure and after_transition_failure callbacks" do
      let(:objects) { build_objects(2) }
      let(:machines) { build_machines(objects) }
      let(:guard_failure_calls) { [] }
      let(:transition_failure_calls) { [] }

      before do
        guard_calls = guard_failure_calls
        transition_calls = transition_failure_calls
        machine_class.after_guard_failure { |object, error| guard_calls << [object, error] }
        machine_class.after_transition_failure { |object, error| transition_calls << [object, error] }
      end

      it "fires after_guard_failure for a machine whose guard fails" do
        machine_class.guard_transition(from: :pending, to: :processing) { |object, *| object != objects[0] }

        described_class.call(machines, :processing)

        expect(guard_failure_calls.map(&:first)).to eq([objects[0]])
        expect(guard_failure_calls.first.last).to be_a(Statesman::GuardFailedError)
        expect(transition_failure_calls).to eq([])
      end

      it "fires after_transition_failure for a machine with an invalid edge" do
        allow_any_instance_of(machine_class).to receive(:current_state).and_return("completed")

        described_class.call(machines, :processing)

        expect(transition_failure_calls.map(&:first)).to match_array(objects)
        expect(transition_failure_calls.first.last).to be_a(Statesman::TransitionFailedError)
        expect(guard_failure_calls).to eq([])
      end

      it "still fires the callback when on_failure: :raise aborts the batch" do
        machine_class.guard_transition(from: :pending, to: :processing) { false }

        expect { described_class.call(machines, :processing, on_failure: :raise) }.
          to raise_error(Statesman::GuardFailedError)

        expect(guard_failure_calls.map(&:first)).to eq([objects[0]])
      end
    end

    describe "on_failure: :raise" do
      let(:objects) { build_objects(2) }
      let(:machines) { build_machines(objects) }

      before do
        capture_transitions!
        machine_class.guard_transition(from: :pending, to: :processing) { false }
      end

      it "raises the underlying error instead of collecting a failure, aborting the batch" do
        expect { described_class.call(machines, :processing, on_failure: :raise) }.
          to raise_error(Statesman::GuardFailedError)

        expect(captured).to be_empty
      end
    end

    describe "skip_guards" do
      let(:objects) { build_objects(2) }
      let(:machines) { build_machines(objects) }

      before { machine_class.guard_transition(from: :pending, to: :processing) { false } }

      it "suppresses guard evaluation, so the transition succeeds" do
        result = described_class.call(machines, :processing, skip_guards: true)

        expect(result.successful).to match_array(objects)
        expect(result.success?).to be(true)
      end
    end

    describe "skip_before_callbacks, skip_after_callbacks, skip_after_commit_callbacks" do
      let(:objects) { build_objects(2) }
      let(:machines) { build_machines(objects) }
      let(:calls) { [] }

      before do
        recorder = calls
        machine_class.before_transition { |*args| recorder << [:before, args] }
        machine_class.after_transition { |*args| recorder << [:after, args] }
        machine_class.after_transition(after_commit: true) { |*args| recorder << [:after_commit, args] }
      end

      it "skips only before when skip_before_callbacks is set" do
        result = described_class.call(machines, :processing, skip_before_callbacks: true)

        expect(calls.map(&:first)).to eq(%i[after after_commit after after_commit])
        expect(result.successful).to match_array(objects)
      end

      it "skips only after when skip_after_callbacks is set" do
        result = described_class.call(machines, :processing, skip_after_callbacks: true)

        expect(calls.map(&:first)).to eq(%i[before before after_commit after_commit])
        expect(result.successful).to match_array(objects)
      end

      it "skips only after_commit when skip_after_commit_callbacks is set" do
        result = described_class.call(machines, :processing, skip_after_commit_callbacks: true)

        expect(calls.map(&:first)).to eq(%i[before before after after])
        expect(result.successful).to match_array(objects)
      end

      it "fires no callbacks at all when all three are set, but still persists the transition" do
        result = described_class.call(machines, :processing, skip_before_callbacks: true,
                                                             skip_after_callbacks: true,
                                                             skip_after_commit_callbacks: true)

        expect(calls).to eq([])
        expect(result.successful).to match_array(objects)
      end
    end

    describe "a batch spanning several from states" do
      let(:pending_object) { model_class.new }
      let(:processing_object) { model_class.new }
      let(:machines) { build_machines([pending_object, processing_object]) }

      before do
        # See the file-level NOTE: stubbing simulates processing_object already being at
        # :processing, exactly what a real persisted adapter would give for free.
        allow_any_instance_of(machine_class).to receive(:current_state) do |instance|
          instance.object == processing_object ? "processing" : "pending"
        end
        machine_class.guard_transition(from: :processing, to: :completed) { false }
      end

      it "buckets by from state and validates/guards each bucket independently" do
        result = described_class.call(machines, :completed)

        expect(result.successful).to eq([pending_object])
        expect(result.failed.map(&:object)).to eq([processing_object])
        expect(result.failed.first.reason).to eq(:guard)
      end
    end

    describe "chunking" do
      let(:objects) { build_objects(5) }
      let(:machines) { build_machines(objects) }

      it "supports calling .call once per caller-defined slice" do
        results = machines.each_slice(2).map do |slice|
          described_class.call(slice, :processing)
        end

        expect(results.flat_map(&:successful)).to match_array(objects)
        expect(results).to all(have_attributes(success?: true))
      end

      describe "in_batches_of" do
        before { capture_transitions! }

        it "runs one validate+persist cycle per batch and merges the results" do
          result = described_class.call(machines, :processing, in_batches_of: 2)

          expect(result.successful).to match_array(objects)
          expect(result.success?).to be(true)
          objects.each { |object| expect(captured[object].to_state).to eq("processing") }
        end

        it "produces the same result as not batching at all" do
          unbatched = described_class.call(machines, :processing)
          batched = described_class.call(build_machines(build_objects(5)), :processing, in_batches_of: 2)

          expect(batched.successful.size).to eq(unbatched.successful.size)
          expect(batched.success?).to eq(unbatched.success?)
        end

        it "catches a duplicate object even when it would land in different batches" do
          object = model_class.new

          expect do
            described_class.call(
              [machine_class.new(object), *build_machines(build_objects(3)), machine_class.new(object)],
              :processing, in_batches_of: 2
            )
          end.to raise_error(ArgumentError, /duplicate objects/)
        end

        context "with a guard failure partway through" do
          before do
            machine_class.guard_transition(from: :pending, to: :processing) { |object, *| object != objects[2] }
          end

          it "reports the guarded object as failed but still persists the other batches" do
            result = described_class.call(machines, :processing, in_batches_of: 2)

            expect(result.successful).to match_array(objects - [objects[2]])
            expect(result.failed.map(&:object)).to eq([objects[2]])
          end
        end

        context "with on_failure: :raise" do
          before do
            machine_class.guard_transition(from: :pending, to: :processing) { |object, *| object != objects[2] }
          end

          it "raises on the failing batch, leaving earlier batches already persisted" do
            expect do
              described_class.call(machines, :processing, in_batches_of: 2, on_failure: :raise)
            end.to raise_error(Statesman::GuardFailedError)

            expect(captured.keys).to match_array(objects.first(2))
          end
        end

        context "with an invalid batch size" do
          it "raises for a zero batch size" do
            expect { described_class.call(machines, :processing, in_batches_of: 0) }.
              to raise_error(ArgumentError, /in_batches_of must be a positive integer/)
          end

          it "raises for a negative batch size" do
            expect { described_class.call(machines, :processing, in_batches_of: -1) }.
              to raise_error(ArgumentError, /in_batches_of must be a positive integer/)
          end
        end

        context "with an invalid conflict_retry_attempts value" do
          it "raises for a zero value" do
            expect { described_class.call(machines, :processing, conflict_retry_attempts: 0) }.
              to raise_error(ArgumentError, /conflict_retry_attempts must be a positive integer/)
          end

          it "raises for a negative value" do
            expect { described_class.call(machines, :processing, conflict_retry_attempts: -1) }.
              to raise_error(ArgumentError, /conflict_retry_attempts must be a positive integer/)
          end
        end
      end
    end
  end
end
