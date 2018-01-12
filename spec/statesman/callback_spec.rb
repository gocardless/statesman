require "spec_helper"

describe Statesman::Callback do
  let(:cb_lambda) { -> {} }
  let(:callback) do
    described_class.new(from: nil, to: nil, callback: cb_lambda)
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

  describe "#applies_to" do
    subject { callback.applies_to?(from: from, to: to) }

    let(:callback) do
      described_class.new(from: :x, to: :y, callback: cb_lambda)
    end

    context "with any from value" do
      let(:from) { nil }

      context "and an allowed to value" do
        let(:to) { :y }

        it { is_expected.to be_truthy }
      end

      context "and a disallowed to value" do
        let(:to) { :a }

        it { is_expected.to be_falsey }
      end
    end

    context "with any to value" do
      let(:to) { nil }

      context "and an allowed 'from' value" do
        let(:from) { :x }

        it { is_expected.to be_truthy }
      end

      context "and a disallowed 'from' value" do
        let(:from) { :a }

        it { is_expected.to be_falsey }
      end
    end

    context "with any to and any from value on the callback" do
      let(:callback) { described_class.new(callback: cb_lambda) }
      let(:from) { :x }
      let(:to) { :y }

      it { is_expected.to be_truthy }
    end

    context "with any from value on the callback" do
      let(:callback) do
        described_class.new(to: %i[y z], callback: cb_lambda)
      end
      let(:from) { :x }

      context "and an allowed to value" do
        let(:to) { :y }

        it { is_expected.to be_truthy }
      end

      context "and another allowed to value" do
        let(:to) { :z }

        it { is_expected.to be_truthy }
      end

      context "and a disallowed to value" do
        let(:to) { :a }

        it { is_expected.to be_falsey }
      end
    end

    context "with any to value on the callback" do
      let(:callback) { described_class.new(from: :x, callback: cb_lambda) }
      let(:to) { :y }

      context "and an allowed to value" do
        let(:from) { :x }

        it { is_expected.to be_truthy }
      end

      context "and a disallowed to value" do
        let(:from) { :a }

        it { is_expected.to be_falsey }
      end
    end

    context "with allowed 'from' and 'to' values" do
      let(:from) { :x }
      let(:to) { :y }

      it { is_expected.to be_truthy }
    end

    context "with disallowed 'from' and 'to' values" do
      let(:from) { :a }
      let(:to) { :b }

      it { is_expected.to be_falsey }
    end
  end
end
