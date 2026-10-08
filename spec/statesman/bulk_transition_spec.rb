# frozen_string_literal: true

# Unit-level dispatch behavior (build/before/persist/after/after_commit, skip options,
# on_failure, failure tagging) now lives entirely in each adapter's own .bulk_create —
# see spec/statesman/adapters/memory_spec.rb and
# spec/statesman/adapters/active_record_bulk_create_spec.rb. #write_batch itself is a
# thin payload-builder/delegator with no interesting behavior of its own to unit-test
# here; see the ".call" describe block below for end-to-end coverage of the public
# entry point, including the equivalence-with-a-loop-of-#transition_to! claim.
describe Statesman::BulkTransition do
  def item_for(machine, metadata: {})
    Statesman::BulkTransition::Item.new(machine: machine, metadata: metadata)
  end

  # NOTE: the memory adapter's history is scoped to a single Machine instance's lifetime,
  # not the parent object, so these specs can't verify results by re-instantiating a
  # fresh machine afterward. They rely on `result.successful`/`result.failed` and a real
  # `after_transition` callback instead.
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

    def build_machines(count, klass: machine_class, transition_class: Statesman::Adapters::MemoryTransition)
      build_objects(count).map { |object| klass.new(object, transition_class: transition_class) }
    end

    def build_items(count, klass: machine_class, transition_class: Statesman::Adapters::MemoryTransition)
      build_machines(count, klass: klass, transition_class: transition_class).map { |machine| item_for(machine) }
    end

    # Registers a real Statesman `after` callback to capture the transition actually
    # written for each object, keyed by object. Does not fire under skip_after_callbacks.
    def capture_transitions!
      store = captured
      machine_class.after_transition { |object, transition| store[object] = transition }
    end

    describe "end-to-end on the memory adapter" do
      subject(:result) { described_class.call(items, from_state: :pending, to_state: :processing) }

      let(:items) { build_items(3) }
      let(:objects) { items.map { |item| item.machine.object } }

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
        described_class.call(items, from_state: :pending, to_state: :processing,
                                    metadata: { "batch_id" => 42 })
        objects.each { |object| expect(captured[object].metadata).to eq({ "batch_id" => 42 }) }
      end

      context "with a mixed batch (some succeed, one is guarded)" do
        let(:good_machine) { machine_class.new(model_class.new) }
        let(:guarded_machine) { machine_class.new(model_class.new) }
        let(:items) { [item_for(good_machine), item_for(guarded_machine)] }

        before do
          guarded_object = guarded_machine.object
          machine_class.guard_transition(from: :pending, to: :processing) { |object, *| object != guarded_object }
        end

        it "partitions successful vs failed correctly" do
          result = described_class.call(items, from_state: :pending, to_state: :processing)

          expect(result.successful).to eq([good_machine.object])
          expect(result.failed).to contain_exactly(having_attributes(object: guarded_machine.object, reason: :guard))
        end
      end
    end

    describe "per-item metadata" do
      let(:machine_a) { machine_class.new(model_class.new) }
      let(:machine_b) { machine_class.new(model_class.new) }

      before { capture_transitions! }

      it "merges each item's metadata over the shared metadata in the written transition" do
        items = [item_for(machine_a, metadata: { "priority" => "high" }), item_for(machine_b)]

        described_class.call(items, from_state: :pending, to_state: :processing, metadata: { "k" => "v" })

        expect(captured[machine_a.object].metadata).to eq({ "k" => "v", "priority" => "high" })
        expect(captured[machine_b.object].metadata).to eq({ "k" => "v" })
      end

      it "is visible to guards, not just the written transition" do
        machine_class.guard_transition(from: :pending, to: :processing) do |_object, _last, metadata|
          metadata["allow"] == true
        end
        items = [item_for(machine_a, metadata: { "allow" => true }),
                 item_for(machine_b, metadata: { "allow" => false })]

        result = described_class.call(items, from_state: :pending, to_state: :processing)

        expect(result.successful).to eq([machine_a.object])
        expect(result.failed).to contain_exactly(having_attributes(object: machine_b.object, reason: :guard))
      end
    end

    describe "machine class extraction" do
      let(:other_machine_class) do
        Class.new(machine_class) do
          def self.name
            "MyOtherBulkStateMachine"
          end
        end
      end

      it "rejects a batch of machines built from different classes, even a base/subclass pair" do
        matching = machine_class.new(model_class.new)
        mismatched = other_machine_class.new(model_class.new)

        expect do
          described_class.call([item_for(matching), item_for(mismatched)], from_state: :pending,
                                                                           to_state: :processing)
        end.to raise_error(ArgumentError, /expects every machine to be the same class/)
      end
    end

    describe "adapter type validation" do
      let(:custom_transition_class) { Class.new(Statesman::Adapters::MemoryTransition) }
      let(:custom_adapter_class) { Class.new(Statesman::Adapters::Memory) }

      before { allow(Statesman).to receive(:storage_adapter).and_return(custom_adapter_class) }

      it "rejects a batch of machines that don't all share the same adapter class" do
        memory_item = build_items(1).first
        custom_item = build_items(1, transition_class: custom_transition_class).first

        expect do
          described_class.call([memory_item, custom_item], from_state: :pending, to_state: :processing)
        end.to raise_error(ArgumentError, /expects every machine to share the same adapter class/)
      end

      it "accepts a batch where every machine shares the same (non-default) adapter class" do
        items = build_items(2, transition_class: custom_transition_class)

        expect do
          described_class.call(items, from_state: :pending, to_state: :processing)
        end.to_not raise_error
      end
    end

    describe "a Machine subclass" do
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

      let(:machine) { sub_class.new(model_class.new) }

      it "validates against the subclass's own guards, not the base class's" do
        result = described_class.call([item_for(machine)], from_state: :pending, to_state: :processing)

        expect(result.successful).to eq([])
        expect(result.failed.first.reason).to eq(:guard)
      end
    end

    describe "equivalence with a loop of #transition_to!" do
      before { capture_transitions! }

      it "produces the same final transition shape" do
        looped = build_objects(2)
        bulked_items = build_items(2)
        looped.each { |object| machine_class.new(object).transition_to!(:processing, { "k" => "v" }) }
        described_class.call(bulked_items, from_state: :pending, to_state: :processing, metadata: { "k" => "v" })
        looped.zip(bulked_items.map { |item| item.machine.object }).each do |looped_object, bulked_object|
          looped_transition = captured[looped_object]

          expect(captured[bulked_object]).to have_attributes(
            from_state: looped_transition.from_state,
            to_state: looped_transition.to_state,
            sort_key: looped_transition.sort_key,
            metadata: looped_transition.metadata,
          )
        end
      end
    end

    describe "a custom transition_class baked into each machine" do
      let(:custom_transition_class) { Class.new(Statesman::Adapters::MemoryTransition) }
      let(:custom_adapter_class) { Class.new(Statesman::Adapters::Memory) }
      let(:items) { build_items(2, transition_class: custom_transition_class) }

      before { allow(Statesman).to receive(:storage_adapter).and_return(custom_adapter_class) }

      it "resolves the adapter class from the machines themselves, not Adapters::Memory" do
        expect(custom_adapter_class).to receive(:bulk_create).and_call_original

        described_class.call(items, from_state: :pending, to_state: :processing)
      end
    end

    describe "successor validation" do
      subject(:call) do
        described_class.call(
          [item_for(machine)], from_state: :pending, to_state: :pending,
                               skip_guards: true, skip_before_callbacks: true,
                               skip_after_callbacks: true, skip_after_commit_callbacks: true
        )
      end

      let(:machine) { machine_class.new(model_class.new) }

      it "is enforced even with every skip option set" do
        # pending has no self-transition declared, so this must fail structurally
        # regardless of the skips — raised immediately, since this is a configuration
        # fact about machine_class, not a per-object runtime outcome.
        expect { call }.to raise_error(Statesman::InvalidTransitionError)
      end
    end

    describe "after_guard_failure and after_transition_failure callbacks" do
      let(:items) { build_items(2) }
      let(:objects) { items.map { |item| item.machine.object } }
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

        described_class.call(items, from_state: :pending, to_state: :processing)

        expect(guard_failure_calls.map(&:first)).to eq([objects[0]])
        expect(guard_failure_calls.first.last).to be_a(Statesman::GuardFailedError)
        expect(transition_failure_calls).to eq([])
      end

      it "raises immediately for an undeclared from/to pair, without touching any callback" do
        # completed has no declared transition to processing — a fact about machine_class
        # itself, not about any of these objects, so nothing is attempted and neither
        # callback fires.
        expect { described_class.call(items, from_state: :completed, to_state: :processing) }.
          to raise_error(Statesman::InvalidTransitionError)

        expect(transition_failure_calls).to eq([])
        expect(guard_failure_calls).to eq([])
      end

      it "still fires the callback when on_failure: :raise aborts the batch" do
        machine_class.guard_transition(from: :pending, to: :processing) { false }

        expect do
          described_class.call(items, from_state: :pending, to_state: :processing,
                                      on_failure: :raise)
        end.to raise_error(Statesman::GuardFailedError)

        expect(guard_failure_calls.map(&:first)).to eq([objects[0]])
      end
    end

    describe "a broken after_guard_failure hook" do
      let(:items) { build_items(3) }
      let(:objects) { items.map { |item| item.machine.object } }

      before do
        machine_class.guard_transition(from: :pending, to: :processing) { |object, *| object == objects[2] }
        machine_class.after_guard_failure { raise StandardError, "boom" }
      end

      it "doesn't stop guard evaluation for the rest of the batch" do
        result = described_class.call(items, from_state: :pending, to_state: :processing)

        expect(result.successful).to eq([objects[2]])
        expect(result.failed.map(&:object)).to match_array(objects[0..1])
      end
    end

    describe "on_failure: :raise" do
      let(:items) { build_items(2) }

      before do
        capture_transitions!
        machine_class.guard_transition(from: :pending, to: :processing) { false }
      end

      it "raises the underlying error instead of collecting a failure, aborting the batch" do
        expect do
          described_class.call(items, from_state: :pending, to_state: :processing,
                                      on_failure: :raise)
        end.to raise_error(Statesman::GuardFailedError)

        expect(captured).to be_empty
      end
    end

    describe "skip_guards" do
      let(:items) { build_items(2) }
      let(:objects) { items.map { |item| item.machine.object } }

      before { machine_class.guard_transition(from: :pending, to: :processing) { false } }

      it "suppresses guard evaluation, so the transition succeeds" do
        result = described_class.call(items, from_state: :pending, to_state: :processing,
                                             skip_guards: true)

        expect(result.successful).to match_array(objects)
        expect(result.success?).to be(true)
      end
    end

    describe "skip_before_callbacks, skip_after_callbacks, skip_after_commit_callbacks" do
      let(:items) { build_items(2) }
      let(:objects) { items.map { |item| item.machine.object } }
      let(:calls) { [] }

      before do
        recorder = calls
        machine_class.before_transition { |*args| recorder << [:before, args] }
        machine_class.after_transition { |*args| recorder << [:after, args] }
        machine_class.after_transition(after_commit: true) { |*args| recorder << [:after_commit, args] }
      end

      it "skips only before when skip_before_callbacks is set" do
        result = described_class.call(items, from_state: :pending, to_state: :processing,
                                             skip_before_callbacks: true)

        expect(calls.map(&:first)).to eq(%i[after after_commit after after_commit])
        expect(result.successful).to match_array(objects)
      end

      it "skips only after when skip_after_callbacks is set" do
        result = described_class.call(items, from_state: :pending, to_state: :processing,
                                             skip_after_callbacks: true)

        expect(calls.map(&:first)).to eq(%i[before after_commit before after_commit])
        expect(result.successful).to match_array(objects)
      end

      it "skips only after_commit when skip_after_commit_callbacks is set" do
        result = described_class.call(items, from_state: :pending, to_state: :processing,
                                             skip_after_commit_callbacks: true)

        expect(calls.map(&:first)).to eq(%i[before after before after])
        expect(result.successful).to match_array(objects)
      end

      it "fires no callbacks at all when all three are set, but still persists the transition" do
        result = described_class.call(items, from_state: :pending, to_state: :processing,
                                             skip_before_callbacks: true,
                                             skip_after_callbacks: true,
                                             skip_after_commit_callbacks: true)

        expect(calls).to eq([])
        expect(result.successful).to match_array(objects)
      end
    end

    describe "chunking" do
      let(:items) { build_items(5) }
      let(:objects) { items.map { |item| item.machine.object } }

      it "supports calling .call once per caller-defined slice" do
        results = items.each_slice(2).map do |slice|
          described_class.call(slice, from_state: :pending, to_state: :processing)
        end

        expect(results.flat_map(&:successful)).to match_array(objects)
        expect(results).to all(have_attributes(success?: true))
      end

      describe "in_batches_of" do
        before { capture_transitions! }

        it "runs one validate+write cycle per batch and merges the results" do
          result = described_class.call(items, from_state: :pending, to_state: :processing,
                                               in_batches_of: 2)

          expect(result.successful).to match_array(objects)
          expect(result.success?).to be(true)
          objects.each { |object| expect(captured[object].to_state).to eq("processing") }
        end

        it "produces the same result as not batching at all" do
          unbatched = described_class.call(items, from_state: :pending, to_state: :processing)
          batched = described_class.call(build_items(5), from_state: :pending,
                                                         to_state: :processing, in_batches_of: 2)

          expect(batched.successful.size).to eq(unbatched.successful.size)
          expect(batched.success?).to eq(unbatched.success?)
        end

        context "with a guard failure partway through" do
          before do
            machine_class.guard_transition(from: :pending, to: :processing) { |object, *| object != objects[2] }
          end

          it "reports the guarded object as failed but still persists the other batches" do
            result = described_class.call(items, from_state: :pending, to_state: :processing,
                                                 in_batches_of: 2)

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
              described_class.call(items, from_state: :pending, to_state: :processing,
                                          in_batches_of: 2, on_failure: :raise)
            end.to raise_error(Statesman::GuardFailedError)

            expect(captured.keys).to match_array(objects.first(2))
          end
        end
      end
    end
  end
end
