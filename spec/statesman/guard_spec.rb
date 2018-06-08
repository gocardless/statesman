require "spec_helper"

describe Statesman::Guard do
  let(:callback) { -> {} }
  let(:guard) { described_class.new(from: nil, to: nil, callback: callback) }

  specify { expect(guard).to be_a(Statesman::Callback) }

  describe "#call" do
    subject(:call) { guard.call }

    context "success" do
      let(:callback) { -> { true } }

      specify { expect { call }.to_not raise_error }
    end

    context "error" do
      let(:callback) { -> { false } }

      specify { expect { call }.to raise_error(Statesman::GuardFailedError) }
    end
  end
end
