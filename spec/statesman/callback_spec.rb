require "spec_helper"

describe Statesman::Callback do
  let(:cb_lambda) { -> {} }
  let(:callback) do
    Statesman::Callback.new(from: nil, to: nil, callback: cb_lambda)
  end

  describe "#initialize" do
    context "with no callback" do
      let(:cb_lambda) { nil }

      it "raises an error" do
        expect { callback }.to raise_error(Statesman::InvalidCallbackError)
      end
    end
  end

  describe "#call" do
    let(:spy) { double.as_null_object }
    let(:cb_lambda) { -> { spy.call } }

    it "delegates to callback" do
      callback.call
      expect(spy).to have_received(:call)
    end
  end
end
