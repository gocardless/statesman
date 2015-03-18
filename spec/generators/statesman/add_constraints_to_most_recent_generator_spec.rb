require "spec_helper"
require "support/generators_shared_examples"
require "generators/statesman/add_constraints_to_most_recent_generator"

describe Statesman::AddConstraintsToMostRecentGenerator, type: :generator do
  it_behaves_like "a generator" do
    let(:migration_name) do
      'db/migrate/add_constraints_to_most_recent_for_bacon_transitions.rb'
    end
  end

  describe "the migration contains the correct words" do
    let(:migration_number) { '5678309' }

    let(:mock_time) do
      double('Time', utc: double('UTCTime', strftime: migration_number))
    end

    subject(:migration_file) do
      file("db/migrate/#{migration_number}_"\
           "add_constraints_to_most_recent_for_bacon_transitions.rb")
    end

    let(:fixture_file) do
      File.read("spec/fixtures/add_constraints_to_most_recent_for_"\
                "bacon_transitions.rb")
    end

    before do
      allow(Time).to receive(:now).and_return(mock_time)
      run_generator %w(Bacon BaconTransition)
    end

    it "matches the fixture" do
      expect(migration_file).to contain(fixture_file)
    end
  end
end
