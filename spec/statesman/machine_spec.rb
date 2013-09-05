require "spec_helper"

describe Statesman::Machine do
  let(:bare_sm) { Class.new { include Statesman::Machine } }
  let(:basic_sm) do
    Class.new do
      include Statesman::Machine
      state :x
      state :y
      state :z
    end
  end

  describe ".state" do
    before { bare_sm.state(:x) }
    before { bare_sm.state(:y) }
    specify { expect(bare_sm.states).to eq([:x, :y]) }
  end

  describe ".transition" do
    context "given neither a 'from' nor a 'to' state" do
      it "raises an error" do
        expect do
          basic_sm.transition
        end.to raise_error(Statesman::InvalidStateError)
      end
    end

    context "given an invalid 'from' state" do
      it "raises an error" do
        expect do
          basic_sm.transition(from: :a, to: :x)
        end.to raise_error(Statesman::InvalidStateError)
      end
    end

    context "given an invalid 'to' state" do
      it "raises an error" do
        expect do
          basic_sm.transition(from: :x, to: :a)
        end.to raise_error(Statesman::InvalidStateError)
      end
    end

    context "valid 'from' and 'to' states" do
      it "records the transition" do
        basic_sm.transition(from: :x, to: :y)
        basic_sm.transition(from: :x, to: :z)
        expect(basic_sm.successors).to eq(x: [:y, :z])
      end
    end
  end
end

