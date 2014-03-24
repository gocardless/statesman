require "spec_helper"

describe Statesman::Adapters::ActiveRecordModel do
  before do
    prepare_model_table
    prepare_transitions_table
  end

  before do
    MyActiveRecordModel.send(:extend, Statesman::Adapters::ActiveRecordModel)
    MyActiveRecordModel.class_eval do
      def self.transition_class
        MyActiveRecordModelTransition
      end
    end
  end

  let!(:model) do
    model = MyActiveRecordModel.create
    model.my_active_record_model_transitions.create(to_state: :state_a)
    model
  end

  let!(:other_model) do
    model = MyActiveRecordModel.create
    model.my_active_record_model_transitions.create(to_state: :state_b)
    model
  end

  describe ".with_states" do
    context "given a single state" do
      subject { MyActiveRecordModel.with_states(:state_a) }

      it { should include model }
    end

    context "given multiple states" do
      subject { MyActiveRecordModel.with_states(:state_a, :state_b) }

      it { should include model }
      it { should include other_model }
    end
  end

  describe ".without_states" do
    context "given a single state" do
      subject { MyActiveRecordModel.without_states(:state_b) }
      it { should include model }
      it { should_not include other_model }
    end

    context "given multiple states" do
      subject { MyActiveRecordModel.without_states(:state_a, :state_b) }
      it { should == [] }
    end
  end
end
