require "spec_helper"
require "support/generators_shared_examples"
require "generators/statesman/add_most_recent_generator"

describe Statesman::AddMostRecentGenerator, type: :generator do
  it_behaves_like "a generator" do
    let(:migration_name) do
      'db/migrate/add_most_recent_to_bacon_transitions.rb'
    end
  end

  describe "the migration" do
    let(:migration_number) { '5678309' }

    let(:mock_time) do
      double('Time', utc: double('UTCTime', strftime: migration_number))
    end

    subject(:migration_file) do
      file("db/migrate/#{migration_number}_"\
           "add_most_recent_to_bacon_transitions.rb")
    end

    let(:fixture_file) do
      File.read("spec/fixtures/add_most_recent_to_bacon_transitions.rb")
    end

    before { allow(Time).to receive(:now).and_return(mock_time) }
    before { run_generator %w(Bacon BaconTransition) }

    it "matches the fixture" do
      expect(migration_file).to contain(fixture_file)
    end
  end
end
