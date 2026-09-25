# frozen_string_literal: true

describe Statesman::Adapters::ActiveRecordTransitionAttributes do
  let(:klass) do
    Class.new do
      def initialize(attributes = {})
        @attributes = attributes
      end

      def has_attribute?(name)
        @attributes.key?(name)
      end

      def [](name)
        @attributes[name]
      end
    end
  end

  describe "including behaviour" do
    it "defaults updated_timestamp_column to :updated_at" do
      klass.include(described_class)

      expect(klass.updated_timestamp_column).to eq(:updated_at)
    end

    it "allows updated_timestamp_column to be overridden" do
      klass.include(described_class)

      klass.updated_timestamp_column = :updated_on

      expect(klass.updated_timestamp_column).to eq(:updated_on)
    end
  end

  describe "#from_state" do
    subject(:from_state) { instance.from_state }

    before { klass.include(described_class) }

    context "when the from_state attribute is present" do
      let(:instance) { klass.new(from_state: "pending") }

      it { is_expected.to eq("pending") }
    end

    context "when the from_state attribute is not present" do
      let(:instance) { klass.new }

      it { is_expected.to be_nil }
    end
  end
end
