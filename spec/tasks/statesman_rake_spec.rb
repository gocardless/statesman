# frozen_string_literal: true

require "rake"

describe "statesman:backfill_most_recent", :active_record, type: :task do
  subject(:backfill) { task.invoke("MyActiveRecordModel") }

  let(:task) { Rake.application["statesman:backfill_most_recent"] }

  # Databases without partial indexes use NULL rather than false for older transitions,
  # so that only one row per parent can match the unique most_recent index.
  let(:not_most_recent) do
    Statesman::Adapters::ActiveRecord.database_supports_partial_indexes?(ActiveRecord::Base) ? false : nil
  end

  let(:model) { MyActiveRecordModel.create }
  let(:other_model) { MyActiveRecordModel.create }
  let(:first) { create_transition(model, sort_key: 10, most_recent: true) }
  let(:latest) { create_transition(model, sort_key: 20, most_recent: not_most_recent) }
  let(:other_latest) { create_transition(other_model, sort_key: 10, most_recent: not_most_recent) }

  around do |example|
    original_application = Rake.application
    Rake.application = Rake::Application.new
    Rake::Task.define_task(:environment)
    load File.expand_path("../../lib/tasks/statesman.rake", __dir__)
    example.run
  ensure
    Rake.application = original_application
  end

  before do
    prepare_model_table
    prepare_transitions_table
    [first, latest, other_latest].each(&:itself)
    # Other specs redefine MyActiveRecordModel.transition_class without restoring it.
    allow(MyActiveRecordModel).to receive(:transition_class).
      and_return(MyActiveRecordModelTransition)
    allow($stdout).to receive(:puts)
  end

  def create_transition(parent, sort_key:, most_recent:)
    MyActiveRecordModelTransition.create!(
      my_active_record_model: parent,
      to_state: "succeeded",
      sort_key: sort_key,
      most_recent: most_recent,
    )
  end

  it "marks the latest transition for each parent as most recent" do
    backfill

    expect([latest, other_latest].map { |t| t.reload.most_recent }).to eq([true, true])
  end

  it "clears most_recent on older transitions" do
    expect { backfill }.to change { first.reload.most_recent }.from(true).to(not_most_recent)
  end

  it "requires a parent model name" do
    expect { task.invoke }.to raise_error(SystemExit)
  end
end
