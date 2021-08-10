# frozen_string_literal: true

require "spec_helper"

describe Statesman do
  describe "InvalidStateError" do
    subject(:error) { Statesman::InvalidStateError.new }

    its(:message) { is_expected.to eq("Statesman::InvalidStateError") }

    its "string matches its message" do
      expect(error.to_s).to eq(error.message)
    end
  end

  describe "InvalidTransitionError" do
    subject(:error) { Statesman::InvalidTransitionError.new }

    its(:message) { is_expected.to eq("Statesman::InvalidTransitionError") }

    its "string matches its message" do
      expect(error.to_s).to eq(error.message)
    end
  end

  describe "InvalidCallbackError" do
    subject(:error) { Statesman::InvalidTransitionError.new }

    its(:message) { is_expected.to eq("Statesman::InvalidTransitionError") }

    its "string matches its message" do
      expect(error.to_s).to eq(error.message)
    end
  end

  describe "TransitionConflictError" do
    subject(:error) { Statesman::TransitionConflictError.new }

    its(:message) { is_expected.to eq("Statesman::TransitionConflictError") }

    its "string matches its message" do
      expect(error.to_s).to eq(error.message)
    end
  end

  describe "MissingTransitionAssociation" do
    subject(:error) { Statesman::MissingTransitionAssociation.new }

    its(:message) { is_expected.to eq("Statesman::MissingTransitionAssociation") }

    its "string matches its message" do
      expect(error.to_s).to eq(error.message)
    end
  end

  describe "TransitionFailedError" do
    subject(:error) { Statesman::TransitionFailedError.new("from", "to") }

    its(:message) { is_expected.to eq("Cannot transition from 'from' to 'to'") }

    its "string matches its message" do
      expect(error.to_s).to eq(error.message)
    end
  end

  describe "GuardFailedError" do
    subject(:error) { Statesman::GuardFailedError.new("from", "to") }

    its(:message) do
      is_expected.to eq("Guard on transition from: 'from' to 'to' returned false")
    end

    its "string matches its message" do
      expect(error.to_s).to eq(error.message)
    end
  end

  describe "UnserializedMetadataError" do
    subject(:error) { Statesman::UnserializedMetadataError.new("foo") }

    its(:message) { is_expected.to match(/foo#metadata is not serialized/) }

    its "string matches its message" do
      expect(error.to_s).to eq(error.message)
    end
  end

  describe "IncompatibleSerializationError" do
    subject(:error) { Statesman::IncompatibleSerializationError.new("foo") }

    its(:message) { is_expected.to match(/foo#metadata column type cannot be json/) }

    its "string matches its message" do
      expect(error.to_s).to eq(error.message)
    end
  end
end
