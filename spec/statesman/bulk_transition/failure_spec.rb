# frozen_string_literal: true

describe Statesman::BulkTransition::Failure do
  subject(:failure) { described_class.new(object: object, reason: reason, error: error) }

  let(:object) { double }
  let(:reason) { :guard }
  let(:error) { StandardError.new("boom") }

  its(:object) { is_expected.to eq(object) }
  its(:reason) { is_expected.to eq(:guard) }
  its(:error) { is_expected.to eq(error) }

  context "without an error" do
    subject(:failure) { described_class.new(object: object, reason: reason) }

    its(:error) { is_expected.to be_nil }
  end

  describe "reason enumeration" do
    %i[guard conflict invalid_current_state].each do |valid_reason|
      context "when reason is #{valid_reason.inspect}" do
        let(:reason) { valid_reason }

        its(:reason) { is_expected.to eq(valid_reason) }
      end
    end

    context "with an unrecognised reason" do
      let(:reason) { :something_else }

      it "raises an ArgumentError" do
        expect { failure }.to raise_error(ArgumentError, /invalid reason/)
      end
    end
  end
end
