require "spec_helper"

describe Statesman::Adapters::ActiveRecordQueries, active_record: true do
  before do
    prepare_model_table
    prepare_transitions_table
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
  end

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

  context "with a most_recent column" do
    describe ".in_state" do
      context "given a single state" do
        subject { MyActiveRecordModel.in_state(:succeeded) }

        it { is_expected.to include model }
        it { is_expected.not_to include other_model }
        its(:to_sql) { is_expected.to include('most_recent') }
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
    end

    describe ".not_in_state" do
      context "given a single state" do
        subject { MyActiveRecordModel.not_in_state(:failed) }
        it { is_expected.to include model }
        it { is_expected.not_to include other_model }
        its(:to_sql) { is_expected.to include('most_recent') }
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
  end

  context "without a most_recent column" do
    before { drop_most_recent_column }

    describe ".in_state" do
      context "given a single state" do
        subject { MyActiveRecordModel.in_state(:succeeded) }

        it { is_expected.to include model }
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
  end
end
