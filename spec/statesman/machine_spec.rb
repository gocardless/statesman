require "spec_helper"

describe Statesman::Machine do
  let(:machine) { Class.new { include Statesman::Machine } }

  describe ".state" do
    before { machine.state(:x) }
    before { machine.state(:y) }
    specify { expect(machine.states).to eq([:x, :y]) }
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
        expect do
          machine.transition
        end.to raise_error(Statesman::InvalidStateError)
      end
    end

    context "given an invalid 'from' state" do
      it "raises an error" do
        expect do
          machine.transition(from: :a, to: :x)
        end.to raise_error(Statesman::InvalidStateError)
      end
    end

    context "given an invalid 'to' state" do
      it "raises an error" do
        expect do
          machine.transition(from: :x, to: :a)
        end.to raise_error(Statesman::InvalidStateError)
      end
    end

    context "valid 'from' and 'to' states" do
      it "records the transition" do
        machine.transition(from: :x, to: :y)
        machine.transition(from: :x, to: :z)
        expect(machine.successors).to eq(x: [:y, :z])
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
        expect do
          machine.validate_callback_condition(from: :z, to: :y)
        end.to raise_error(Statesman::InvalidTransitionError)
      end
    end

    context "with an initial 'to' state" do
      it "raises an exception" do
        expect do
          machine.validate_callback_condition(from: :y, to: :x)
        end.to raise_error(Statesman::InvalidTransitionError)
      end
    end

    context "with an invalid transition" do
      it "raises an exception" do
        expect do
          machine.validate_callback_condition(from: :x, to: :z)
        end.to raise_error(Statesman::InvalidTransitionError)
      end
    end

    context "with any states" do
      it "does not raise an exception" do
        expect { machine.validate_callback_condition }.to_not raise_error
      end
    end

    context "with a valid transition" do
      it "does not raise an exception" do
        expect do
          machine.validate_callback_condition(from: :x, to: :y)
        end.to_not raise_error
      end
    end
  end

  shared_examples "a callback store" do |assignment_method, callback_store|
    it "stores callbacks" do
      cb = -> {  }
      machine.send(assignment_method, &cb)
      expect(machine.send(callback_store)).to include([nil, nil, cb])
    end

    it "raises an exception when invalid states are passed" do
      expect do
        machine.send(assignment_method, from: :foo, to: :bar)
      end.to raise_error(Statesman::InvalidStateError)
    end
  end

  describe ".before_transition" do
    it_behaves_like "a callback store", :before_transition, :before_callbacks
  end

  describe ".after_transition" do
    it_behaves_like "a callback store", :after_transition, :after_callbacks
  end

  describe ".guard_transition" do
    it_behaves_like "a callback store", :guard_transition, :guards
  end

  describe "#transition_to!" do
    before do
      machine.class_eval do
        state :x
        state :y
        state :z
        transition from: :x, to: :y
        transition from: :y, to: :z
      end
    end

    let(:instance) { machine.new }

    context "when the state cannot be transitioned to" do
      before { instance.current_state = :x }

      it "raises an error" do
        expect do
          instance.transition_to!(:z)
        end.to raise_error(Statesman::InvalidTransitionError)
      end
    end

    context "when the state can be transitioned to" do
      before { instance.current_state = :x }

      it "changes state" do
        instance.transition_to!(:y)
        expect(instance.current_state).to eq(:y)
      end

      context "with a guard" do
        before { machine.guard_transition(from: :x, to: :y) { result } }
        context "which passes" do
          let(:result) { true }

          it "changes state" do
            instance.transition_to!(:y)
            expect(instance.current_state).to eq(:y)
          end
        end

        context "which fails" do
          let(:result) { false }

          it "raises an exception" do
            expect do
              instance.transition_to!(:y)
            end.to raise_error(Statesman::GuardFailedError)
          end
        end
      end

      context "with a before callback" do
        let(:spy) { double.as_null_object }
        let(:callback) { -> { spy.call } }
        before { machine.before_transition(from: :x, to: :y, &callback) }

        it "is called before the state transition" do
          spy.should_receive(:call).once do
            expect(instance.current_state).to eq(:x)
          end
          instance.transition_to!(:y)
          expect(instance.current_state).to eq(:y)
        end
      end

      context "with an after callback" do
        let(:spy) { double.as_null_object }
        let(:callback) { -> { spy.call } }
        before { machine.after_transition(from: :x, to: :y, &callback) }

        it "is called after the state transition" do
          spy.should_receive(:call).once do
            expect(instance.current_state).to eq(:y)
          end
          instance.transition_to!(:y)
        end
      end
    end
  end

  describe "#transition_to" do
    let(:instance) { machine.new }
    subject { instance.transition_to(:some_state) }

    context "when it is succesful" do
      before { instance.stub(:transition_to!).and_return(true) }
      it { should be_true }
    end

    context "when it is unsuccesful" do
      before do
        instance.stub(:transition_to!).and_raise(Statesman::GuardFailedError)
      end
      it { should be_false }
    end
  end

  shared_examples "a callback filter" do |definer, getter|
    before do
      machine.class_eval do
        state :x
        state :y
        state :z
        transition from: :x, to: :y
        transition from: :y, to: :z
      end
    end

    let(:instance) { machine.new }
    let(:callbacks) { instance.send(getter, from: :x, to: :y) }

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
        expect(callbacks).to include(callback_1)
      end

      it "does not contain the irrelevant callback" do
        expect(callbacks).to_not include(callback_2)
      end
    end
  end

  describe "#guards_for" do
    it_behaves_like "a callback filter", :guard_transition, :guards_for
  end

  describe "#before_callbacks_for" do
    it_behaves_like "a callback filter", :before_transition,
                    :before_callbacks_for
  end

  describe "#after_callbacks_for" do
    it_behaves_like "a callback filter", :after_transition,
                    :after_callbacks_for
  end
end
