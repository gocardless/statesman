require "spec_helper"
require "support/generators_shared_examples"
require "generators/statesman/active_record_transition_generator"

describe Statesman::ActiveRecordTransitionGenerator, type: :generator do
  it_behaves_like "a generator" do
    let(:migration_name) { "db/migrate/create_bacon_transitions.rb" }
  end

  describe "creates a migration" do
    subject(:migration) { file("db/migrate/#{time}_create_bacon_transitions.rb") }

    before do
      allow(Time).to receive(:now).and_return(mock_time)
      run_generator %w[Yummy::Bacon Yummy::BaconTransition]
    end

    let(:mock_time) { double("Time", utc: double("UTCTime", strftime: time)) }
    let(:time) { "5678309" }

    it "includes a foreign key" do
      expect(migration).to contain("add_foreign_key :bacon_transitions, :bacons")
    end
  end

  describe "properly adds class names" do
    subject { file("app/models/yummy/bacon_transition.rb") }

    before { run_generator %w[Yummy::Bacon Yummy::BaconTransition] }

    it { is_expected.to contain(/:bacon_transition/) }
    it { is_expected.to_not contain(%r{:yummy/bacon}) }
    it { is_expected.to contain(/class_name: 'Yummy::Bacon'/) }
  end

  describe "properly formats without class names" do
    subject { file("app/models/bacon_transition.rb") }

    before { run_generator %w[Bacon BaconTransition] }

    it { is_expected.to_not contain(/class_name:/) }
    it { is_expected.to contain(/class BaconTransition/) }
  end

  describe "it doesn't create any double-spacing" do
    subject { file("app/models/yummy/bacon_transition.rb") }

    before { run_generator %w[Yummy::Bacon Yummy::BaconTransition] }

    it { is_expected.to_not contain(/\n\n\n/) }
  end
end
