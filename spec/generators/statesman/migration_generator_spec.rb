require "spec_helper"
require "support/generators_shared_examples"
require "generators/statesman/migration_generator"

describe Statesman::MigrationGenerator, type: :generator do

  it_behaves_like "a generator" do
    let(:migration_name) { 'db/migrate/add_statesman_to_bacon_transitions.rb' }
  end

  describe 'the model contains the correct words' do
    let(:migration_number) { '5678309' }
    let(:mock_time) { double('Time', utc: double('UTCTime', strftime: migration_number)) }

    subject { 
      file("db/migrate/#{migration_number}_add_statesman_to_bacon_transitions.rb") 
    }

    before { 
      Time.stub(:now).and_return(mock_time)
      run_generator %w[Yummy::Bacon Yummy::BaconTransition]
    } 

    it { should contain(%r[:bacon_transition]) }
    it { should_not contain(%r[:yummy/bacon]) }
  end

end
