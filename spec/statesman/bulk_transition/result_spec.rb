# frozen_string_literal: true

describe Statesman::BulkTransition::Result do
  subject(:result) { described_class.new(successful: successful, failed: failed) }

  let(:successful) { [] }
  let(:failed) { [] }

  describe "defaults" do
    subject(:result) { described_class.new }

    its(:successful) { is_expected.to eq([]) }
    its(:failed) { is_expected.to eq([]) }
    its(:success?) { is_expected.to be(true) }
  end

  describe "#successful" do
    let(:successful) { [double, double] }

    its(:successful) { is_expected.to eq(successful) }
  end

  describe "#failed" do
    let(:failed) { [double] }

    its(:failed) { is_expected.to eq(failed) }
  end

  describe "#success?" do
    context "when nothing failed" do
      its(:success?) { is_expected.to be(true) }
    end

    context "when something failed" do
      let(:failed) { [double] }

      its(:success?) { is_expected.to be(false) }
    end
  end

  describe "#status" do
    context "when everything succeeded" do
      let(:successful) { [double] }
      let(:failed) { [] }

      its(:status) { is_expected.to eq(:all) }
    end

    context "when some succeeded and some failed" do
      let(:successful) { [double] }
      let(:failed) { [double] }

      its(:status) { is_expected.to eq(:partial) }
    end

    context "when nothing succeeded" do
      let(:successful) { [] }
      let(:failed) { [double] }

      its(:status) { is_expected.to eq(:none) }
    end
  end
end
