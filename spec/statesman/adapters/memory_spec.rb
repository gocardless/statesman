require "spec_helper"

describe Statesman::Adapters::Memory do
  let(:adapter) { Statesman::Adapters::Memory.new(Statesman::Transition) }

  describe "#initialize" do
    subject { adapter }
    its(:transition_class) { should be(Statesman::Transition) }
    its(:history) { should eq([]) }
  end

  describe "#create" do
    let(:from) { :x }
    let(:to) { :y }
    let(:create) { adapter.create(from, to) }
    subject { -> { create } }

    it { should change(adapter.history, :count).by(1) }

    context "the new transition" do
      let(:subject) { create }
      it { should be_a(Statesman::Transition) }
      its(:from) { should be(from) }
      its(:to) { should be(to) }
    end
  end

  describe "#last" do
    before do
      adapter.create(:x, :y)
      adapter.create(:y, :z)
    end
    subject { adapter.last }

    it { should be_a(Statesman::Transition) }
    its(:from) { should be(:y) }
    its(:to) { should be(:z) }
  end
end
