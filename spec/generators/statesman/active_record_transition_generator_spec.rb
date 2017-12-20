require "spec_helper"
require "support/generators_shared_examples"
require "generators/statesman/active_record_transition_generator"

describe Statesman::ActiveRecordTransitionGenerator, type: :generator do
  it_behaves_like "a generator" do
    let(:migration_name) { "db/migrate/create_bacon_transitions.rb" }
  end

  describe "creates a migration" do
    subject { file("db/migrate/#{time}_create_bacon_transitions.rb") }

    before { allow(Time).to receive(:now).and_return(mock_time) }
    before { run_generator %w[Yummy::Bacon Yummy::BaconTransition] }

    let(:mock_time) { double("Time", utc: double("UTCTime", strftime: time)) }
    let(:time) { "5678309" }

    it "includes a foreign key" do
      expect(subject).to contain("add_foreign_key :bacon_transitions, :bacons")
    end
  end

  describe "properly adds class names" do
    before { run_generator %w[Yummy::Bacon Yummy::BaconTransition] }
    subject { file("app/models/yummy/bacon_transition.rb") }

    it { is_expected.to contain(/:bacon_transition/) }
    it { is_expected.not_to contain(%r{:yummy/bacon}) }
    it { is_expected.to contain(/class_name: 'Yummy::Bacon'/) }
  end

  describe "properly formats without class names" do
    before { run_generator %w[Bacon BaconTransition] }
    subject { file("app/models/bacon_transition.rb") }

    it { is_expected.not_to contain(/class_name:/) }
    it { is_expected.to contain(/class BaconTransition/) }
  end

  describe "it doesn't create any double-spacing" do
    before { run_generator %w[Yummy::Bacon Yummy::BaconTransition] }
    subject { file("app/models/yummy/bacon_transition.rb") }

    it { is_expected.to_not contain(/\n\n\n/) }
  end
end
