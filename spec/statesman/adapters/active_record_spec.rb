require "spec_helper"

describe Statesman::Adapters::ActiveRecord do
  before do
    prepare_model_table
    prepare_transitions_table
  end

  let(:model) { MyModel.create(current_state: :pending) }
  let(:adapter) do
    Statesman::Adapters::ActiveRecord.new(MyModelTransition, model)
  end

  describe "#initialize" do
    subject { adapter }
    its(:transition_class) { should be(MyModelTransition) }
    its(:parent_model) { should be(model) }
  end

  describe "#create" do
    let(:from) { :x }
    let(:to) { :y }
    let(:create) { adapter.create(from, to) }
    subject { -> { create } }

    it { should change(adapter.history, :count).by(1) }

    context "the new transition" do
      let(:subject) { create }

      it { should be_a(MyModelTransition) }
      its(:from) { should be(from) }
      its(:to) { should be(to) }
    end
  end

  describe "#history" do
    subject { adapter.history }
    it { should eq([]) }

    context "with transitions" do
      let!(:transition) { adapter.create(:x, :y) }
      it { should eq([transition]) }
    end
  end

  describe "#last" do
    before do
      adapter.create(:x, :y)
      adapter.create(:y, :z)
    end
    subject { adapter.last }

    it { should be_a(MyModelTransition) }
    its(:from) { should eq("y") }
    its(:to) { should eq("z") }
  end
end
