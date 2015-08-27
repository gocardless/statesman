require "spec_helper"

describe Statesman::Adapters::ActiveRecordQueries, active_record: true do
  before do
    prepare_model_table
    prepare_transitions_table
    prepare_other_model_table
    prepare_other_transitions_table
  end

  before do
    Statesman.configure { storage_adapter(Statesman::Adapters::ActiveRecord) }
  end
  after { Statesman.configure { storage_adapter(Statesman::Adapters::Memory) } }

  before do
    MyActiveRecordModel.send(:include, Statesman::Adapters::ActiveRecordQueries)
    MyActiveRecordModel.class_eval do
      def self.transition_class
        MyActiveRecordModelTransition
      end

      def self.initial_state
        :initial
      end
    end

    OtherActiveRecordModel.send(:include,
                                Statesman::Adapters::ActiveRecordQueries)
    OtherActiveRecordModel.class_eval do
      def self.transition_class
        OtherActiveRecordModelTransition
      end

      def self.initial_state
        :initial
      end
    end
  end
  before { MyActiveRecordModel.send(:has_one, :other_active_record_model) }
  before { OtherActiveRecordModel.send(:belongs_to, :my_active_record_model) }

  let!(:model) do
    model = MyActiveRecordModel.create
    model.state_machine.transition_to(:succeeded)
    model
  end

  let!(:other_model) do
    model = MyActiveRecordModel.create
    model.state_machine.transition_to(:failed)
    model
  end

  let!(:initial_state_model) { MyActiveRecordModel.create }

  let!(:returned_to_initial_model) do
    model = MyActiveRecordModel.create
    model.state_machine.transition_to(:failed)
    model.state_machine.transition_to(:initial)
    model
  end

  describe ".in_state" do
    context "given a single state" do
      subject { MyActiveRecordModel.in_state(:succeeded) }

      it { is_expected.to include model }
      it { is_expected.not_to include other_model }
    end

    context "given multiple states" do
      subject { MyActiveRecordModel.in_state(:succeeded, :failed) }

      it { is_expected.to include model }
      it { is_expected.to include other_model }
    end

    context "given the initial state" do
      subject { MyActiveRecordModel.in_state(:initial) }

      it { is_expected.to include initial_state_model }
      it { is_expected.to include returned_to_initial_model }
    end

    context "given an array of states" do
      subject { MyActiveRecordModel.in_state([:succeeded, :failed]) }

      it { is_expected.to include model }
      it { is_expected.to include other_model }
    end

    context "merging two queries" do
      subject do
        MyActiveRecordModel.in_state(:succeeded).
          joins(:other_active_record_model).
          merge(OtherActiveRecordModel.in_state(:initial))
      end

      it { is_expected.to be_empty }
    end
  end

  describe ".not_in_state" do
    context "given a single state" do
      subject { MyActiveRecordModel.not_in_state(:failed) }
      it { is_expected.to include model }
      it { is_expected.not_to include other_model }
    end

    context "given multiple states" do
      subject { MyActiveRecordModel.not_in_state(:succeeded, :failed) }
      it do
        is_expected.to match_array([initial_state_model,
                                    returned_to_initial_model])
      end
    end

    context "given an array of states" do
      subject { MyActiveRecordModel.not_in_state([:succeeded, :failed]) }
      it do
        is_expected.to match_array([initial_state_model,
                                    returned_to_initial_model])
      end
    end
  end

  context "with a transition name" do
    before do
      MyActiveRecordModel.send(:has_many,
                               :custom_name,
                               class_name: 'MyActiveRecordModelTransition')
      MyActiveRecordModel.class_eval do
        def self.transition_name
          :custom_name
        end
      end
    end

    describe ".in_state" do
      subject(:query) { MyActiveRecordModel.in_state(:succeeded) }
      specify { expect { query }.to_not raise_error }
    end
  end
end
