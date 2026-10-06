# frozen_string_literal: true

describe Statesman::BulkTransition::Item do
  subject(:item) { described_class.new(machine: machine, metadata: metadata) }

  let(:machine) { double }
  let(:metadata) { { "k" => "v" } }

  its(:machine) { is_expected.to eq(machine) }
  its(:metadata) { is_expected.to eq(metadata) }

  describe "defaults" do
    subject(:item) { described_class.new(machine: machine) }

    its(:metadata) { is_expected.to eq({}) }
  end
end
