require "spec_helper"

# All adpators must define six methods:
#   initialize:       Accepts a transition class and a parent model.
#   transition_class: Returns the transition class object passed to initialize.
#   parent_model:     Returns the model class object passed to initialize.
#   create:           Accepts from, to and optional metadata. Creates a new
#                     transition class
#   history:          Returns the full transition history
#   last:             Returns the latest transition history item
#
shared_examples_for "an adapter" do |adapter_class, transition_class|
  let(:adapter) { adapter_class.new(transition_class, model) }

  describe "#initialize" do
    subject { adapter }
    its(:transition_class) { should be(transition_class) }
    its(:parent_model) { should be(model) }
    its(:history) { should eq([]) }
  end

  describe "#create" do
    let(:from) { :x }
    let(:to) { :y }
    let(:create) { adapter.create(from, to) }
    subject { -> { create } }

    it { should change(adapter.history, :count).by(1) }

    context "the new transition" do
      subject { create }
      it { should be_a(transition_class) }
      its(:from) { should be(from) }
      its(:to) { should be(to) }
    end

    context "with metadata" do
      let(:metadata) { { some: :hash } }
      subject { adapter.create(from, to, metadata) }
      its(:metadata) { should eq(metadata.to_json) }
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

    it { should be_a(transition_class) }
    specify { expect(adapter.last.from.to_sym).to eq(:y) }
    specify { expect(adapter.last.to.to_sym).to eq(:z) }
  end
end
