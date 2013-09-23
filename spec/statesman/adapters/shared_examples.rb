require "spec_helper"

# All adpators must define seven methods:
#   initialize:       Accepts a transition class, parent model and state_attr.
#   transition_class: Returns the transition class object passed to initialize.
#   parent_model:     Returns the model class object passed to initialize.
#   state_attr:       Returns the state attribute to set on the parent.
#   create:           Accepts to_state, before callbacks, after callbacks and
#                     optional metadata. Creates a new transition class
#                     instance and transforms metadata to a JSON string.
#   history:          Returns the full transition history
#   last:             Returns the latest transition history item
#
shared_examples_for "an adapter" do |adapter_class, transition_class|
  let(:adapter) { adapter_class.new(transition_class, model) }
  let(:before_cbs) { [] }
  let(:after_cbs) { [] }

  describe "#initialize" do
    subject { adapter }
    its(:transition_class) { should be(transition_class) }
    its(:parent_model) { should be(model) }
    its(:history) { should eq([]) }
  end

  describe "#create" do
    let(:to) { :y }
    let(:create) { adapter.create(to, before_cbs, after_cbs) }
    subject { -> { create } }

    it { should change(adapter.history, :count).by(1) }

    context "the new transition" do
      subject { create }
      it { should be_a(transition_class) }
      its(:to_state) { should be(to) }

      context "with no previous transition" do
        its(:sort_key) { should be(0) }
      end

      context "with a previous transition" do
        before { adapter.create(:x, before_cbs, after_cbs) }
        its(:sort_key) { should be(10) }
      end
    end

    context "with before callbacks" do
      let(:callback) { double(call: true) }
      let(:before_cbs) { [callback] }

      it "is called before the state transition" do
        callback.should_receive(:call).with do |passed_model, transition|
          expect(passed_model).to be(model)
          expect(transition).to be_a(adapter.transition_class)
          expect(adapter.history.length).to eq(0)
        end.once

        adapter.create(:x, before_cbs, after_cbs)
        expect(adapter.history.length).to eq(1)
      end
    end

    context "with after callbacks" do
      let(:callback) { double(call: true) }
      let(:after_cbs) { [callback] }

      it "is called after the state transition" do
        callback.should_receive(:call).with do |passed_model, transition|
          expect(passed_model).to be(model)
          expect(adapter.last).to eq(transition)
        end.once
        adapter.create(:x, before_cbs, after_cbs)
      end
    end

    context "with metadata" do
      let(:metadata) { { some: :hash } }
      subject { adapter.create(to, before_cbs, after_cbs, metadata) }
      its(:metadata) { should eq(metadata.to_json) }
    end
  end

  describe "#history" do
    subject { adapter.history }
    it { should eq([]) }

    context "with transitions" do
      let!(:transition) { adapter.create(:y, before_cbs, after_cbs) }
      it { should eq([transition]) }
    end
  end

  describe "#last" do
    before do
      adapter.create(:y, before_cbs, after_cbs)
      adapter.create(:z, before_cbs, after_cbs)
    end
    subject { adapter.last }

    it { should be_a(transition_class) }
    specify { expect(adapter.last.to_state.to_sym).to eq(:z) }
  end
end
