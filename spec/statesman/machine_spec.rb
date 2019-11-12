require "spec_helper"

describe Statesman::Machine do
  let(:machine) { Class.new { include Statesman::Machine } }
  let(:my_model) { Class.new { attr_accessor :current_state }.new }

  describe ".state" do
    before { machine.state(:x) }

    before { machine.state(:y) }

    specify { expect(machine.states).to eq(%w[x y]) }

    context "initial" do
      before { machine.state(:x, initial: true) }

      specify { expect(machine.initial_state).to eq("x") }

      context "when an initial state is already defined" do
        it "raises an error" do
          expect { machine.state(:y, initial: true) }.
            to raise_error(Statesman::InvalidStateError)
        end
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
          begin
            set_callback
          rescue error_type
            nil
          end
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

  describe "#initialize" do
    it "accepts an object to manipulate" do
      machine_instance = machine.new(my_model)
      expect(machine_instance.object).to be(my_model)
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
      before { instance.transition_to!(:y) }

      before { instance.transition_to!(:z) }

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
    end

    let(:instance) { machine.new(my_model) }

    before { instance.transition_to!(:y) }

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
                my_model, nil
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
          expect(transition_failed_cb).to receive(:call).once.
            with(my_model, nil).and_return(true)
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

    context "when it is succesful" do
      before do
        expect(instance).to receive(:transition_to!).once.
          with(:some_state, metadata).and_return(:some_state)
      end

      it { is_expected.to be(:some_state) }
    end

    context "when it is unsuccesful" do
      before do
        allow(instance).to receive(:transition_to!).
          and_raise(Statesman::GuardFailedError)
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
      let(:callback_1) { -> { "Hi" } }
      let(:callback_2) { -> { "Bye" } }

      before do
        machine.send(definer, from: :x, to: :y, &callback_1)
        machine.send(definer, from: :y, to: :z, &callback_2)
      end

      it "contains the relevant callback" do
        expect(callbacks.map(&:callback)).to include(callback_1)
      end

      it "does not contain the irrelevant callback" do
        expect(callbacks.map(&:callback)).to_not include(callback_2)
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
