require "spec_helper"

describe Statesmin::Guard do
  let(:callback) { -> {} }
  let(:guard) { Statesmin::Guard.new(from: nil, to: nil, callback: callback) }

  specify { expect(guard).to be_a(Statesmin::Callback) }

  describe "#call" do
    subject(:call) { guard.call }

    context "success" do
      let(:callback) { -> { true } }
      specify { expect { call }.to_not raise_error }
    end

    context "error" do
      let(:callback) { -> { false } }
      specify { expect { call }.to raise_error(Statesmin::GuardFailedError) }
    end
  end
end
