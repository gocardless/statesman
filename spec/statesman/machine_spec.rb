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

  describe "#transition_to" do
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
          instance.transition_to(:z)
        end.to raise_error(Statesman::InvalidTransitionError)
      end
    end
  end
end

