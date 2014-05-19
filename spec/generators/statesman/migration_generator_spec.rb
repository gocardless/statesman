require "spec_helper"
require "support/generators_shared_examples"
require "generators/statesman/migration_generator"

describe Statesman::MigrationGenerator, type: :generator do

  it_behaves_like "a generator" do
    let(:migration_name) { 'db/migrate/add_statesman_to_bacon_transitions.rb' }
  end

  describe 'the model contains the correct words' do
    let(:migration_number) { '5678309' }

    let(:mock_time) do
      double('Time', utc: double('UTCTime', strftime: migration_number))
    end

    subject do
      file(
        "db/migrate/#{migration_number}_add_statesman_to_bacon_transitions.rb"
      )
    end

    before do
      Time.stub(:now).and_return(mock_time)
      run_generator %w[Yummy::Bacon Yummy::BaconTransition]
    end

    it { should contain(/:bacon_transition/) }
    it { should_not contain(/:yummy\/bacon/) }
  end
end
