# frozen_string_literal: true

describe Statesman::Machine do
  let(:machine) do
    Class.new do
      include Statesman::Machine

      def self.name
        "MyStateMachine"
      end
    end
  end
  let(:my_model) { Class.new { attr_accessor :current_state }.new }

  describe ".state" do
    before do
      machine.state(:x)
      machine.state(:y)
    end

    specify { expect(machine.states).to eq(%w[x y]) }

    specify { expect(machine::X).to eq "x" }

    specify { expect(machine::Y).to eq "y" }

    context "initial" do
      before { machine.state(:z, initial: true) }

      specify { expect(machine.initial_state).to eq("z") }

      context "when an initial state is already defined" do
        it "raises an error" do
          expect { machine.state(:y, initial: true) }.
            to raise_error(Statesman::InvalidStateError)
        end
      end
    end

    context "when state name constant is already defined" do
      context "with the same value" do
        it "does not raise an error" do
          machine.const_set(:SOME_CONST, "some_const")
          expect { machine.state(:some_const) }.to_not raise_error
        end
      end

      context "with a different value" do
        it "raises an error about state constant conflict" do
          machine.const_set(:SOME_CONST, "some_const_different")

          expect { machine.state(:some_const) }.to raise_error(
            Statesman::StateConstantConflictError, "Name conflict: 'MyStateMachine::SOME_CONST' is " \
                                                   "already defined as 'some_const_different' " \
                                                   "attempting to redefine as 'some_const'"
          )
        end
      end
    end
  end

  describe ".remove_state" do
    subject(:remove_state) { machine.remove_state(:x) }

    before do
      machine.class_eval do
        state :x
        state :y
        state :z
      end
    end

    it "removes the state" do
      expect { remove_state }.
        to change(machine, :states).
        from(match_array(%w[x y z])).
        to(%w[y z])
    end

    context "with a transition from the removed state" do
      before { machine.transition from: :x, to: :y }

      it "removes the transition" do
        expect { remove_state }.
          to change(machine, :successors).
          from({ "x" => ["y"] }).
          to({})
      end

      context "with multiple transitions" do
        before { machine.transition from: :x, to: :z }

        it "removes all transitions" do
          expect { remove_state }.
            to change(machine, :successors).
            from({ "x" => %w[y z] }).
            to({})
        end
      end
    end

    context "with a transition to the removed state" do
      before { machine.transition from: :y, to: :x }

      it "removes the transition" do
        expect { remove_state }.
          to change(machine, :successors).
          from({ "y" => ["x"] }).
          to({})
      end

      context "with multiple transitions" do
        before { machine.transition from: :z, to: :x }

        it "removes all transitions" do
          expect { remove_state }.
            to change(machine, :successors).
            from({ "y" => ["x"], "z" => ["x"] }).
            to({})
        end
      end
    end

    context "with a callback from the removed state" do
      before do
        machine.class_eval do
          transition from: :x, to: :y
          transition from: :x, to: :z
          guard_transition(from: :x) { return false }
          guard_transition(from: :x, to: :z) { return true }
        end
      end

      let(:guards) do
        [having_attributes(from: "x", to: []), having_attributes(from: "x", to: ["z"])]
      end

      it "removes the guard" do
        expect { remove_state }.
          to change(machine, :callbacks).
          from(a_hash_including(guards: match_array(guards))).
          to(a_hash_including(guards: []))
      end
    end

    context "with a callback to the removed state" do
      before do
        machine.class_eval do
          transition from: :y, to: :x
          guard_transition(to: :x) { return false }
          guard_transition(from: :y, to: :x) { return true }
        end
      end

      let(:guards) do
        [having_attributes(from: nil, to: ["x"]), having_attributes(from: "y", to: ["x"])]
      end

      it "removes the guard" do
        expect { remove_state }.
          to change(machine, :callbacks).
          from(a_hash_including(guards: match_array(guards))).
          to(a_hash_including(guards: []))
      end
    end
  end

  describe ".retry_conflicts" do
    subject(:transition_state) do
      described_class.retry_conflicts(retry_attempts) do
        instance.transition_to(:y)
      end
    end

    before do
      machine.class_eval do
        state :x, initial: true
        state :y
        state :z
        transition from: :x, to: :y
        transition from: :y, to: :z
      end
    end

    let(:instance) { machine.new(my_model) }
    let(:retry_attempts) { 2 }

    context "when no exception occurs" do
      it "runs the transition once" do
        expect(instance).to receive(:transition_to).once
        transition_state
      end
    end

    context "when an irrelevant exception occurs" do
      it "runs the transition once" do
        expect(instance).
          to receive(:transition_to).once.
          and_raise(StandardError)
        begin
          transition_state
        rescue StandardError
          nil
        end
      end

      it "re-raises the exception" do
        allow(instance).to receive(:transition_to).once.
          and_raise(StandardError)
        expect { transition_state }.to raise_error(StandardError)
      end
    end

    context "when a TransitionConflictError occurs" do
      context "and is resolved on the second attempt" do
        it "runs the transition twice" do
          expect(instance).
            to receive(:transition_to).once.
            and_raise(Statesman::TransitionConflictError).
            ordered
          expect(instance).
            to receive(:transition_to).once.ordered.and_call_original
          transition_state
        end
      end

      context "and keeps occurring" do
        it "runs the transition `retry_attempts + 1` times" do
          expect(instance).
            to receive(:transition_to).
            exactly(retry_attempts + 1).times.
            and_raise(Statesman::TransitionConflictError)
          begin
            transition_state
          rescue StandardError
            nil
          end
        end

        it "re-raises the conflict" do
          allow(instance).
            to receive(:transition_to).
            and_raise(Statesman::TransitionConflictError)
          expect { transition_state }.
            to raise_error(Statesman::TransitionConflictError)
        end
      end
    end
  end

  describe ".transition" do
    before do
      machine.class_eval do
        state :x
        state :y
        state :z
      end
    end

    context "given neither a 'from' nor a 'to' state" do
      it "raises an error" do
        expect { machine.transition }.
          to raise_error(Statesman::InvalidStateError)
      end
    end

    context "given no 'from' state and a valid 'to' state" do
      it "raises an error" do
        expect { machine.transition from: nil, to: :x }.
          to raise_error(Statesman::InvalidStateError)
      end
    end

    context "given a valid 'from' state and a no 'to' state" do
      it "raises an error" do
        expect { machine.transition from: :x, to: nil }.
          to raise_error(Statesman::InvalidStateError)
      end
    end

    context "given a valid 'from' state and an empty 'to' state array" do
      it "raises an error" do
        expect { machine.transition from: :x, to: [] }.
          to raise_error(Statesman::InvalidStateError)
      end
    end

    context "given an invalid 'from' state" do
      it "raises an error" do
        expect { machine.transition(from: :a, to: :x) }.
          to raise_error(Statesman::InvalidStateError)
      end
    end

    context "given an invalid 'to' state" do
      it "raises an error" do
        expect { machine.transition(from: :x, to: :a) }.
          to raise_error(Statesman::InvalidStateError)
      end
    end

    context "valid 'from' and 'to' states" do
      it "records the transition" do
        machine.transition(from: :x, to: :y)
        machine.transition(from: :x, to: :z)
        expect(machine.successors).to eq("x" => %w[y z])
      end
    end
  end

  describe ".remove_transitions" do
    before do
      machine.class_eval do
        state :x
        state :y
        state :z
        transition from: :x, to: :y
        transition from: :x, to: :z
        transition from: :y, to: :z
      end
    end

    let(:initial_successors) { { "x" => %w[y z], "y" => ["z"] } }

    it "removes the correct transitions when given a from state" do
      expect { machine.remove_transitions(from: :x) }.
        to change(machine, :successors).
        from(initial_successors).
        to({ "y" => ["z"] })
    end

    it "removes the correct transitions when given a to state" do
      expect { machine.remove_transitions(to: :z) }.
        to change(machine, :successors).
        from(initial_successors).
        to({ "x" => ["y"] })
    end

    it "removes the correct transitions when given a from and to state" do
      expect { machine.remove_transitions(from: :x, to: :z) }.
        to change(machine, :successors).
        from(initial_successors).
        to({ "x" => ["y"], "y" => ["z"] })
    end
  end

  describe ".validate_callback_condition" do
    before do
      machine.class_eval do
        state :x
        state :y
        state :z
        transition from: :x, to: :y
        transition from: :y, to: :z
      end
    end

    context "with a terminal 'from' state" do
      it "raises an exception" do
        expect { machine.validate_callback_condition(from: :z, to: :y) }.
          to raise_error(Statesman::InvalidTransitionError)
      end
    end

    context "with an initial 'to' state" do
      it "raises an exception" do
        expect { machine.validate_callback_condition(from: :y, to: :x) }.
          to raise_error(Statesman::InvalidTransitionError)
      end
    end

    context "with an invalid transition" do
      it "raises an exception" do
        expect { machine.validate_callback_condition(from: :x, to: :z) }.
          to raise_error(Statesman::InvalidTransitionError)
      end
    end

    context "with any states" do
      it "does not raise an exception" do
        expect { machine.validate_callback_condition }.to_not raise_error
      end
    end

    context "with a valid transition" do
      it "does not raise an exception" do
        expect { machine.validate_callback_condition(from: :x, to: :y) }.
          to_not raise_error
      end
    end
  end

  shared_examples "a callback store" do |assignment_method, callback_store|
    before do
      machine.class_eval do
        state :x, initial: true
        state :y
        state :z
        transition from: :x, to: %i[y z]
      end
    end

    let(:options) { { from: nil, to: [] } }
    let(:set_callback) { machine.send(assignment_method, options) {} }

    shared_examples "fails" do |error_type|
      specify { expect { set_callback }.to raise_error(error_type) }

      it "does not add a callback" do
        expect do
          set_callback
        rescue error_type
          nil
        end.to_not change(machine.callbacks[callback_store], :count)
      end
    end

    shared_examples "adds callback" do
      specify { expect { set_callback }.to_not raise_error }

      it "stores callbacks" do
        expect { set_callback }.
          to change(machine.callbacks[callback_store], :count).by(1)
      end

      it "stores callback instances" do
        set_callback
        machine.callbacks[callback_store].each do |callback|
          expect(callback).to be_a(Statesman::Callback)
        end
      end
    end

    context "with invalid states" do
      context "when both are invalid" do
        let(:options) { { from: :foo, to: :bar } }

        it_behaves_like "fails", Statesman::InvalidStateError
      end

      context "from a terminal state to anything" do
        let(:options) { { from: :y, to: [] } }

        it_behaves_like "fails", Statesman::InvalidTransitionError
      end

      context "to an initial state and from anything" do
        let(:options) { { from: nil, to: :x } }

        it_behaves_like "fails", Statesman::InvalidTransitionError
      end

      context "from a terminal state and to multiple states" do
        let(:options) { { from: :y, to: %i[x z] } }

        it_behaves_like "fails", Statesman::InvalidTransitionError
      end

      context "to an initial state and other states" do
        let(:options) { { from: nil, to: %i[y x z] } }

        it_behaves_like "fails", Statesman::InvalidTransitionError
      end
    end

    context "with validate_states" do
      context "from anything" do
        let(:options) { { from: nil, to: :y } }

        it_behaves_like "adds callback"
      end

      context "to anything" do
        let(:options) { { from: :x, to: [] } }

        it_behaves_like "adds callback"
      end

      context "to several" do
        let(:options) { { from: :x, to: %i[y z] } }

        it_behaves_like "adds callback"
      end

      context "from any to several" do
        let(:options) { { from: nil, to: %i[y z] } }

        it_behaves_like "adds callback"
      end
    end
  end

  describe ".before_transition" do
    it_behaves_like "a callback store", :before_transition, :before
  end

  describe ".after_transition" do
    it_behaves_like "a callback store", :after_transition, :after
  end

  describe ".guard_transition" do
    it_behaves_like "a callback store", :guard_transition, :guards
  end

  describe ".after_transition_failure" do
    it_behaves_like "a callback store",
                    :after_transition_failure,
                    :after_transition_failure
  end

  describe ".after_guard_failure" do
    it_behaves_like "a callback store", :after_guard_failure, :after_guard_failure
  end

  describe ".validate_bulk_transition" do
    subject(:call) do
      machine.validate_bulk_transition(machines, from: "pending", to: "approved", on_failure: on_failure)
    end

    let(:order_a) { Class.new { attr_accessor :current_state }.new }
    let(:order_b) { Class.new { attr_accessor :current_state }.new }
    let(:machine_a) { machine.new(order_a) }
    let(:machine_b) { machine.new(order_b) }
    let(:machines) { [machine_a, machine_b] }
    let(:on_failure) { :collect }

    before do
      machine.class_eval do
        state :pending, initial: true
        state :approved
        state :rejected
        transition from: :pending, to: :approved
      end
    end

    it "returns every machine as a survivor, with no failures" do
      survivors, failed = call
      expect(survivors).to eq(machines)
      expect(failed).to eq([])
    end

    context "with an invalid edge (to is not a successor of from)" do
      subject(:call) do
        machine.validate_bulk_transition(machines, from: "pending", to: "rejected", on_failure: on_failure)
      end

      it "returns no survivors, tagging every machine as invalid_current_state" do
        survivors, failed = call
        expect(survivors).to eq([])
        expect(failed).to contain_exactly(
          include(machine: machine_a, reason: :invalid_current_state),
          include(machine: machine_b, reason: :invalid_current_state),
        )
      end

      context "and on_failure is :raise" do
        let(:on_failure) { :raise }

        it "raises immediately instead of collecting failures" do
          expect { call }.to raise_error(Statesman::TransitionFailedError)
        end
      end
    end

    context "with a guard" do
      before { machine.guard_transition(from: :pending, to: :approved) { |object, *| object != order_b } }

      it "partitions survivors from guard failures" do
        survivors, failed = call
        expect(survivors).to eq([machine_a])
        expect(failed).to contain_exactly(include(machine: machine_b, reason: :guard))
      end

      context "and on_failure is :raise" do
        let(:on_failure) { :raise }

        it "raises immediately instead of collecting failures" do
          expect { call }.to raise_error(Statesman::GuardFailedError)
        end
      end
    end

    context "with skip_guards: true" do
      subject(:call) do
        machine.validate_bulk_transition(machines, from: "pending", to: "approved", skip_guards: true,
                                                   on_failure: on_failure)
      end

      before { machine.guard_transition(from: :pending, to: :approved) { false } }

      it "suppresses guard evaluation, so every machine survives" do
        survivors, failed = call
        expect(survivors).to eq(machines)
        expect(failed).to eq([])
      end
    end
  end

  # NOTE on verification strategy: the memory adapter's history is scoped to a single
  # Machine instance's lifetime (Adapters::Memory#initialize always starts `@history =
  # []`), not to the parent object — this is pre-existing and unrelated to bulk
  # transitions (a fresh `machine_class.new(model)` never sees a transition written by a
  # *different* instance for the same model, with or without bulk_transition_to! — this
  # was confirmed on unmodified code too: `klass.new(m).transition_to!(:y)` followed by a
  # fresh `klass.new(m).current_state` returns "x", not "y"). bulk_transition_to! itself
  # only ever builds one machine per object per call and uses it consistently for that call,
  # so this doesn't affect correctness — but it does mean these specs can't verify
  # results by re-instantiating a fresh machine afterward. Instead they rely on
  # `result.successful`/`result.failed` (built during the call itself), a real
  # `after_transition` callback to capture written transitions where deeper properties
  # matter, and `allow_any_instance_of` (already used elsewhere in this file) on the rare
  # occasion a test needs objects starting from different states within one call.
  describe ".bulk_transition_to!" do
    let(:machine_class) do
      Class.new do
        include Statesman::Machine

        def self.name
          "MyBulkStateMachine"
        end

        state :x, initial: true
        state :y
        state :z
        transition from: :x, to: :y
        transition from: :x, to: :z
        transition from: :y, to: :z
      end
    end

    let(:model_class) { Class.new { attr_accessor :current_state } }
    let(:captured) { {} }

    def build_objects(count)
      Array.new(count) { model_class.new }
    end

    # Registers a real Statesman `after` callback to capture the transition actually
    # written for each object, keyed by object. Does not fire under skip_after_callbacks.
    def capture_transitions!
      store = captured
      machine_class.after_transition { |object, transition| store[object] = transition }
    end

    describe "end-to-end on the memory adapter" do
      subject(:result) { machine_class.bulk_transition_to!(objects, :y) }

      let(:objects) { build_objects(3) }

      before { capture_transitions! }

      it "transitions every object and reports no failures" do
        expect(result.successful).to match_array(objects)
        expect(result.failed).to eq([])
        expect(result.success?).to be(true)
      end

      it "actually writes each object's transition to state y" do
        result
        objects.each { |object| expect(captured[object].to_state).to eq("y") }
      end

      it "applies the given metadata to every transition in the batch" do
        machine_class.bulk_transition_to!(objects, :y, metadata: { "batch_id" => 42 })
        objects.each { |object| expect(captured[object].metadata).to eq({ "batch_id" => 42 }) }
      end

      context "with a mixed batch (some succeed, one is guarded, one has a bad edge)" do
        let(:good_object) { model_class.new }
        let(:guarded_object) { model_class.new }
        let(:invalid_object) { model_class.new }
        let(:objects) { [good_object, guarded_object, invalid_object] }

        before do
          machine_class.guard_transition(from: :x, to: :y) { |object, *| object != guarded_object }

          # invalid_object needs a *different* starting state than the other two so that
          # :y is not a declared successor of it; see the file-level NOTE on why this is
          # stubbed rather than set up via a real prior transition.
          allow_any_instance_of(machine_class).to receive(:current_state) do |instance|
            instance.object == invalid_object ? "z" : "x"
          end
        end

        it "partitions successful vs failed correctly" do
          result = machine_class.bulk_transition_to!(objects, :y)

          expect(result.successful).to eq([good_object])
          expect(result.failed).to contain_exactly(
            having_attributes(object: guarded_object, reason: :guard),
            having_attributes(object: invalid_object, reason: :invalid_current_state),
          )
        end
      end
    end

    describe "accepting pre-built machines instead of objects" do
      let(:object) { model_class.new }
      let(:pre_built_machine) { machine_class.new(object) }

      it "uses the given machine instance directly, without building a new one" do
        pre_built_machine
        expect(machine_class).to_not receive(:new)

        result = machine_class.bulk_transition_to!([pre_built_machine], :y)

        expect(result.successful).to eq([object])
      end
    end

    describe "a pre-built machine that's a subclass of the receiver" do
      let(:sub_class) do
        Class.new(machine_class) do
          def self.name
            "MyBulkSubStateMachine"
          end

          state :x, initial: true
          state :y
          transition from: :x, to: :y
          guard_transition(from: :x, to: :y) { false }
        end
      end

      let(:object) { model_class.new }
      let(:sub_machine) { sub_class.new(object) }

      it "validates against the subclass's own guards, not the receiver's" do
        result = machine_class.bulk_transition_to!([sub_machine], :y)

        expect(result.successful).to eq([])
        expect(result.failed.first.reason).to eq(:guard)
      end
    end

    describe "duplicate objects" do
      let(:object) { model_class.new }

      it "raises instead of persisting the same object twice" do
        expect { machine_class.bulk_transition_to!([object, object], :y) }.
          to raise_error(ArgumentError, /duplicate objects/)
      end
    end

    describe "equivalence with a loop of #transition_to!" do
      before { capture_transitions! }

      it "produces the same final transition shape" do
        looped = build_objects(2)
        bulked = build_objects(2)

        looped.each { |object| machine_class.new(object).transition_to!(:y, { "k" => "v" }) }
        machine_class.bulk_transition_to!(bulked, :y, metadata: { "k" => "v" })

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
        machine_class.bulk_transition_to!([object], :x, skip_guards: true, skip_before_callbacks: true,
                                                        skip_after_callbacks: true,
                                                        skip_after_commit_callbacks: true)
      end

      let(:object) { model_class.new }

      it "is enforced even with every skip option set" do
        # x has no self-edge declared, so this must fail structurally regardless of the
        # skips.
        expect(result.successful).to eq([])
        expect(result.failed.first.reason).to eq(:invalid_current_state)
      end
    end

    describe "on_failure: :raise" do
      let(:objects) { build_objects(2) }

      before do
        capture_transitions!
        machine_class.guard_transition(from: :x, to: :y) { false }
      end

      it "raises the underlying error instead of collecting a failure, aborting the batch" do
        expect { machine_class.bulk_transition_to!(objects, :y, on_failure: :raise) }.
          to raise_error(Statesman::GuardFailedError)

        expect(captured).to be_empty
      end
    end

    describe "skip_guards" do
      let(:objects) { build_objects(2) }

      before { machine_class.guard_transition(from: :x, to: :y) { false } }

      it "suppresses guard evaluation, so the transition succeeds" do
        result = machine_class.bulk_transition_to!(objects, :y, skip_guards: true)

        expect(result.successful).to match_array(objects)
        expect(result.success?).to be(true)
      end
    end

    describe "skip_before_callbacks, skip_after_callbacks, skip_after_commit_callbacks" do
      let(:objects) { build_objects(2) }
      let(:calls) { [] }

      before do
        recorder = calls
        machine_class.before_transition { |*args| recorder << [:before, args] }
        machine_class.after_transition { |*args| recorder << [:after, args] }
        machine_class.after_transition(after_commit: true) { |*args| recorder << [:after_commit, args] }
      end

      it "skips only before when skip_before_callbacks is set" do
        result = machine_class.bulk_transition_to!(objects, :y, skip_before_callbacks: true)

        expect(calls.map(&:first)).to eq(%i[after after_commit after after_commit])
        expect(result.successful).to match_array(objects)
      end

      it "skips only after when skip_after_callbacks is set" do
        result = machine_class.bulk_transition_to!(objects, :y, skip_after_callbacks: true)

        expect(calls.map(&:first)).to eq(%i[before before after_commit after_commit])
        expect(result.successful).to match_array(objects)
      end

      it "skips only after_commit when skip_after_commit_callbacks is set" do
        result = machine_class.bulk_transition_to!(objects, :y, skip_after_commit_callbacks: true)

        expect(calls.map(&:first)).to eq(%i[before before after after])
        expect(result.successful).to match_array(objects)
      end

      it "fires no callbacks at all when all three are set, but still persists the transition" do
        result = machine_class.bulk_transition_to!(objects, :y, skip_before_callbacks: true,
                                                                skip_after_callbacks: true,
                                                                skip_after_commit_callbacks: true)

        expect(calls).to eq([])
        expect(result.successful).to match_array(objects)
      end
    end

    describe "a batch spanning several from states" do
      let(:x_object) { model_class.new }
      let(:y_object) { model_class.new }

      before do
        # See the file-level NOTE: stubbing simulates y_object already being at :y,
        # exactly what a real persisted adapter would give for free.
        allow_any_instance_of(machine_class).to receive(:current_state) do |instance|
          instance.object == y_object ? "y" : "x"
        end
        machine_class.guard_transition(from: :y, to: :z) { false }
      end

      it "buckets by from state and validates/guards each bucket independently" do
        result = machine_class.bulk_transition_to!([x_object, y_object], :z)

        expect(result.successful).to eq([x_object])
        expect(result.failed.map(&:object)).to eq([y_object])
        expect(result.failed.first.reason).to eq(:guard)
      end
    end

    describe "chunking" do
      let(:objects) { build_objects(5) }

      it "supports calling bulk_transition_to! once per caller-defined slice" do
        results = objects.each_slice(2).map { |slice| machine_class.bulk_transition_to!(slice, :y) }

        expect(results.flat_map(&:successful)).to match_array(objects)
        expect(results).to all(have_attributes(success?: true))
      end

      describe "in_batches_of" do
        before { capture_transitions! }

        it "runs one validate+persist cycle per batch and merges the results" do
          result = machine_class.bulk_transition_to!(objects, :y, in_batches_of: 2)

          expect(result.successful).to match_array(objects)
          expect(result.success?).to be(true)
          objects.each { |object| expect(captured[object].to_state).to eq("y") }
        end

        it "produces the same result as not batching at all" do
          unbatched = machine_class.bulk_transition_to!(objects, :y)
          batched = machine_class.bulk_transition_to!(build_objects(5), :y, in_batches_of: 2)

          expect(batched.successful.size).to eq(unbatched.successful.size)
          expect(batched.success?).to eq(unbatched.success?)
        end

        it "catches a duplicate object even when it would land in different batches" do
          object = model_class.new

          expect { machine_class.bulk_transition_to!([object, *build_objects(3), object], :y, in_batches_of: 2) }.
            to raise_error(ArgumentError, /duplicate objects/)
        end

        context "with a guard failure partway through" do
          before { machine_class.guard_transition(from: :x, to: :y) { |object, *| object != objects[2] } }

          it "reports the guarded object as failed but still persists the other batches" do
            result = machine_class.bulk_transition_to!(objects, :y, in_batches_of: 2)

            expect(result.successful).to match_array(objects - [objects[2]])
            expect(result.failed.map(&:object)).to eq([objects[2]])
          end
        end

        context "with on_failure: :raise" do
          before { machine_class.guard_transition(from: :x, to: :y) { |object, *| object != objects[2] } }

          it "raises on the failing batch, leaving earlier batches already persisted" do
            expect { machine_class.bulk_transition_to!(objects, :y, in_batches_of: 2, on_failure: :raise) }.
              to raise_error(Statesman::GuardFailedError)

            expect(captured.keys).to match_array(objects.first(2))
          end
        end

        context "with an invalid batch size" do
          it "raises for a zero batch size" do
            expect { machine_class.bulk_transition_to!(objects, :y, in_batches_of: 0) }.
              to raise_error(ArgumentError, /in_batches_of must be a positive integer/)
          end

          it "raises for a negative batch size" do
            expect { machine_class.bulk_transition_to!(objects, :y, in_batches_of: -1) }.
              to raise_error(ArgumentError, /in_batches_of must be a positive integer/)
          end
        end
      end
    end
  end

  shared_examples "initial transition is not created" do
    it "doesn't call .create on storage adapter" do
      expect_any_instance_of(Statesman.storage_adapter).to_not receive(:create)
      machine.new(my_model, options)
    end
  end

  shared_examples "initial transition is created" do
    it "calls .create on storage adapter" do
      expect_any_instance_of(Statesman.storage_adapter).to receive(:create).with(nil, "x")
      machine.new(my_model, options)
    end

    it "creates a new transition object" do
      instance = machine.new(my_model, options)

      expect(instance.history.count).to eq(1)
      expect(instance.history.first.to_state).to eq("x")
    end
  end

  describe "#initialize" do
    it "accepts an object to manipulate" do
      machine_instance = machine.new(my_model)
      expect(machine_instance.object).to be(my_model)
    end

    context "initial_transition is not provided" do
      let(:options) { {} }

      it_behaves_like "initial transition is not created"
    end

    context "initial_transition is provided" do
      context "initial_transition is true" do
        let(:options) do
          { initial_transition: true,
            transition_class: Statesman::Adapters::MemoryTransition }
        end

        context "history is empty" do
          context "initial state is defined" do
            before { machine.state(:x, initial: true) }

            it_behaves_like "initial transition is created"
          end

          context "initial state is not defined" do
            it_behaves_like "initial transition is not created"
          end
        end

        context "history is not empty" do
          before do
            allow_any_instance_of(Statesman.storage_adapter).to receive(:history).
              and_return([{}])
          end

          context "initial state is defined" do
            before { machine.state(:x, initial: true) }

            it_behaves_like "initial transition is not created"
          end

          context "initial state is not defined" do
            it_behaves_like "initial transition is not created"
          end
        end
      end

      context "initial_transition is false" do
        let(:options) { { initial_transition: false } }

        it_behaves_like "initial transition is not created"
      end
    end

    context "transition class" do
      it "sets a default" do
        expect(Statesman.storage_adapter).to receive(:new).once.
          with(Statesman::Adapters::MemoryTransition,
               my_model, anything, anything)
        machine.new(my_model)
      end

      it "sets the passed class" do
        my_transition_class = Class.new
        expect(Statesman.storage_adapter).to receive(:new).once.
          with(my_transition_class, my_model, anything, anything)
        machine.new(my_model, transition_class: my_transition_class)
      end

      it "falls back to Memory without transaction_class" do
        allow(Statesman).to receive(:storage_adapter).and_return(Class.new)
        expect(Statesman::Adapters::Memory).to receive(:new).once.
          with(Statesman::Adapters::MemoryTransition,
               my_model, anything, anything)
        machine.new(my_model)
      end
    end
  end

  describe "#after_initialize" do
    it "is called after initialize" do
      machine.class_eval do
        def after_initialize; end
      end
      expect_any_instance_of(machine).to receive :after_initialize
      machine.new(my_model)
    end
  end

  describe "#current_state" do
    subject { instance.current_state }

    before do
      machine.class_eval do
        state :x, initial: true
        state :y
        state :z
        transition from: :x, to: :y
        transition from: :y, to: :z
      end
    end

    let(:instance) { machine.new(my_model) }

    context "with no transitions" do
      it { is_expected.to eq(machine.initial_state) }
    end

    context "with multiple transitions" do
      before do
        instance.transition_to!(:y)
        instance.transition_to!(:z)
      end

      it { is_expected.to eq("z") }
    end
  end

  describe "#in_state?" do
    subject { instance.in_state?(state) }

    before do
      machine.class_eval do
        state :x, initial: true
        state :y
        transition from: :x, to: :y
      end
      instance.transition_to!(:y)
    end

    let(:instance) { machine.new(my_model) }

    context "when machine is in given state" do
      let(:state) { "y" }

      it { is_expected.to eq(true) }
    end

    context "when machine is not in given state" do
      let(:state) { "x" }

      it { is_expected.to eq(false) }
    end

    context "when given a symbol" do
      let(:state) { :y }

      it { is_expected.to eq(true) }
    end

    context "when given multiple states" do
      context "when given multiple arguments" do
        context "when one of the states is the current state" do
          subject { instance.in_state?(:x, :y) }

          it { is_expected.to eq(true) }
        end

        context "when none of the states are the current state" do
          subject { instance.in_state?(:x, :z) }

          it { is_expected.to eq(false) }
        end
      end

      context "when given an array" do
        context "when one of the states is the current state" do
          subject { instance.in_state?(%i[x y]) }

          it { is_expected.to eq(true) }
        end

        context "when none of the states are the current state" do
          subject { instance.in_state?(%i[x z]) }

          it { is_expected.to eq(false) }
        end
      end
    end
  end

  describe "#allowed_transitions" do
    subject { instance.allowed_transitions(metadata) }

    before do
      machine.class_eval do
        state :x, initial: true
        state :y
        state :z
        transition from: :x, to: %i[y z]
        transition from: :y, to: :z
      end
    end

    let(:instance) { machine.new(my_model) }
    let(:metadata) { { some: :metadata } }

    context "with multiple possible states" do
      it { is_expected.to eq(%w[y z]) }
    end

    context "with one possible state" do
      before { instance.transition_to!(:y) }

      it { is_expected.to eq(["z"]) }

      context "guarded using metadata" do
        before do
          machine.guard_transition(to: :z) do |_, _, metadata|
            metadata[:some] == :metadata
          end
        end

        it { is_expected.to eq(["z"]) }
      end

      context "excluded by guard using metadata" do
        before do
          machine.guard_transition(to: :z) do |_, _, metadata|
            metadata[:some] != :metadata
          end
        end

        it { is_expected.to eq([]) }
      end
    end

    context "with no possible transitions" do
      before { instance.transition_to!(:z) }

      it { is_expected.to eq([]) }
    end
  end

  describe "#last_transition" do
    let(:instance) { machine.new(my_model) }
    let(:last_action) { "Whatever" }

    it "delegates to the storage adapter" do
      expect_any_instance_of(Statesman.storage_adapter).to receive(:last).once.
        and_return(last_action)
      expect(instance.last_transition).to be(last_action)
    end
  end

  describe "#last_transition_to" do
    subject { instance.last_transition_to(:y) }

    before do
      machine.class_eval do
        state :x, initial: true
        state :y
        state :z
        transition from: :x, to: :y
        transition from: :y, to: :z
        transition from: :z, to: :y
      end

      instance.transition_to!(:y)
      instance.transition_to!(:z)
    end

    let(:instance) { machine.new(my_model) }

    it { is_expected.to have_attributes(to_state: "y") }

    context "when there are 2 transitions to the state" do
      before { instance.transition_to!(:y) }

      it { is_expected.to eq(instance.last_transition) }
    end
  end

  describe "#can_transition_to?" do
    subject(:can_transition_to?) { instance.can_transition_to?(new_state, metadata) }

    before do
      machine.class_eval do
        state :x, initial: true
        state :y
        state :z
        transition from: :x, to: :y
        transition from: :y, to: :z
      end
    end

    let(:instance) { machine.new(my_model) }
    let(:metadata) { { some: :metadata } }

    context "when the transition is invalid" do
      context "with an initial to state" do
        let(:new_state) { :x }

        it { is_expected.to be_falsey }
      end

      context "with a terminal from state" do
        before { instance.transition_to!(:y) }

        let(:new_state) { :y }

        it { is_expected.to be_falsey }
      end

      context "and is guarded" do
        let(:guard_cb) { -> { false } }
        let(:new_state) { :z }

        before { machine.guard_transition(to: new_state, &guard_cb) }

        it "does not fire guard" do
          expect(guard_cb).to_not receive(:call)
          expect(can_transition_to?).to be_falsey
        end
      end
    end

    context "when the transition valid" do
      let(:new_state) { :y }

      it { is_expected.to be_truthy }

      context "but it has a failing guard" do
        before { machine.guard_transition(to: :y) { false } }

        it { is_expected.to be_falsey }
      end

      context "but it has a failing guard based on metadata" do
        before do
          machine.guard_transition(to: :y) do |_, _, metadata|
            metadata[:some] != :metadata
          end
        end

        it { is_expected.to be_falsey }
      end

      context "and has a passing guard based on metadata" do
        before do
          machine.guard_transition(to: :y) do |_, _, metadata|
            metadata[:some] == :metadata
          end
        end

        it { is_expected.to be_truthy }
      end
    end
  end

  describe "#transition_to!" do
    before do
      machine.class_eval do
        state :x, initial: true
        state :y
        state :z
        transition from: :x, to: :y
        transition from: :y, to: :z
      end
    end

    let(:instance) { machine.new(my_model) }

    context "when the state cannot be transitioned to" do
      it "raises an error" do
        # Hardcoding error message here to ensure backward
        # compatibility as people may have been parsing the string
        # to figure out the transitions involved.
        expect { instance.transition_to!(:z) }.
          to raise_error(Statesman::TransitionFailedError,
                         "Cannot transition from 'x' to 'z'")
      end
    end

    context "when the state can be transitioned to" do
      it "changes state" do
        instance.transition_to!(:y)
        expect(instance.current_state).to eq("y")
      end

      it "creates a new transition object" do
        expect { instance.transition_to!(:y) }.
          to change(instance.history, :count).by(1)

        expect(instance.history.first).
          to be_a(Statesman::Adapters::MemoryTransition)
        expect(instance.history.first.to_state).to eq("y")
      end

      it "sends metadata to the transition object" do
        meta = { "my" => "hash" }
        instance.transition_to!(:y, meta)
        expect(instance.history.first.metadata).to eq(meta)
      end

      it "sets an empty hash as the metadata if not specified" do
        instance.transition_to!(:y)
        expect(instance.history.first.metadata).to eq({})
      end

      specify { expect(instance.transition_to!(:y)).to be_truthy }

      context "with a guard" do
        let(:result) { true }
        let(:guard_cb) { ->(*_args) { result } }

        before { machine.guard_transition(from: :x, to: :y, &guard_cb) }

        context "and an object to act on" do
          let(:instance) { machine.new(my_model) }

          it "passes the object to the guard" do
            expect(guard_cb).to receive(:call).once.
              with(my_model, instance.last_transition, {}).and_return(true)
            instance.transition_to!(:y)
          end
        end

        context "which covers all transitions" do
          let(:result) { true }
          let(:guard_cb) { ->(*_args) { false } }

          before { machine.guard_transition(from: :x, to: :y, &guard_cb) }

          it "raises an exception with the transition information" do
            expect(guard_cb).to receive(:call).once.with(
              my_model, instance.last_transition, {}
            ).and_return(false)
            expect { instance.transition_to!(:y) }.
              to raise_error(
                an_instance_of(Statesman::GuardFailedError).
                and(having_attributes(from: "x", to: ["y"], object: my_model)),
              )
          end
        end

        context "which passes" do
          it "changes state" do
            instance.transition_to!(:y)
            expect(instance.current_state).to eq("y")
          end
        end

        context "which fails" do
          let(:result) { false }

          it "raises an exception" do
            expect { instance.transition_to!(:y) }.
              to raise_error(Statesman::GuardFailedError)
          end

          context "and a guard failed callback defined" do
            let(:guard_failure_result) { true }
            let(:guard_failure_cb) { ->(*_args) { guard_failure_result } }

            before { machine.after_guard_failure(from: :x, to: :y, &guard_failure_cb) }

            it "calls the failure callback" do
              expect(guard_failure_cb).to receive(:call).once.with(
                my_model, instance_of(Statesman::GuardFailedError)
              ).and_return(guard_failure_result)
              expect { instance.transition_to!(:y) }.
                to raise_error(Statesman::GuardFailedError)
            end
          end
        end
      end

      context "with a transition failed callback" do
        let(:result) { true }
        let(:transition_failed_cb) { ->(*_args) { result } }
        let(:instance) { machine.new(my_model) }

        before do
          machine.after_transition_failure(&transition_failed_cb)
        end

        it "raises and exception and calls the callback" do
          expect(transition_failed_cb).to receive(:call).once.with(
            my_model, instance_of(Statesman::TransitionFailedError)
          ).and_return(true)
          expect { instance.transition_to!(:z) }.
            to raise_error(Statesman::TransitionFailedError)
        end
      end
    end
  end

  describe "#transition_to" do
    subject { instance.transition_to(:some_state, metadata) }

    let(:instance) { machine.new(my_model) }
    let(:metadata) { { some: :metadata } }

    context "when it is successful" do
      before do
        expect(instance).to receive(:transition_to!).once.
          with(:some_state, metadata).and_return(:some_state)
      end

      it { is_expected.to be(:some_state) }
    end

    context "when it is unsuccessful" do
      before do
        allow(instance).to receive(:transition_to!).
          and_raise(Statesman::GuardFailedError.new(:x, :some_state, nil))
      end

      it { is_expected.to be_falsey }
    end

    context "when a non statesman exception is raised" do
      before do
        allow(instance).to receive(:transition_to!).
          and_raise(RuntimeError, "user defined exception")
      end

      it "does not rescue the exception" do
        expect { instance.transition_to(:some_state, metadata) }.
          to raise_error(RuntimeError, "user defined exception")
      end
    end
  end

  shared_examples "a callback filter" do |definer, phase|
    before do
      machine.class_eval do
        state :x
        state :y
        state :z
        transition from: :x, to: :y
        transition from: :y, to: :z
      end
    end

    let(:instance) { machine.new(my_model) }
    let(:callbacks) { instance.send(:callbacks_for, phase, from: :x, to: :y) }

    context "with no defined callbacks" do
      specify { expect(callbacks).to eq([]) }
    end

    context "with defined callbacks" do
      let(:callback_one) { -> { "Hi" } }
      let(:callback_two) { -> { "Bye" } }

      before do
        machine.send(definer, from: :x, to: :y, &callback_one)
        machine.send(definer, from: :y, to: :z, &callback_two)
      end

      it "contains the relevant callback" do
        expect(callbacks.map(&:callback)).to include(callback_one)
      end

      it "does not contain the irrelevant callback" do
        expect(callbacks.map(&:callback)).to_not include(callback_two)
      end
    end
  end

  describe "#guards_for" do
    it_behaves_like "a callback filter", :guard_transition, :guards
  end

  describe "#before_callbacks_for" do
    it_behaves_like "a callback filter", :before_transition, :before
  end

  describe "#after_callbacks_for" do
    it_behaves_like "a callback filter", :after_transition, :after
  end
end
