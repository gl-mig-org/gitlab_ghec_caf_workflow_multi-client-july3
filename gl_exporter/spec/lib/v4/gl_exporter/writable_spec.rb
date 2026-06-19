# frozen_string_literal: true
require "spec_helper"

describe GlExporter::Writable, :v4 do
  let(:pseudo_exporter) { PseudoExporter.new(pseudo_model) }

  let(:pseudo_model) do
    PseudoModel.new.tap do |model|
      model["web_url"] = "http://hostname.com/path"
    end
  end

  let(:archiver) { double GlExporter::ArchiveBuilder }
  let(:serializer) { double GlExporter::RepositorySerializer }

  before(:each) do
    PseudoExporter.include(GlExporter::Writable)
    allow(pseudo_exporter).to receive(:archiver).and_return(archiver)
    allow(GlExporter::RepositorySerializer).to receive(:new).and_return(serializer)
  end

  describe "#serialize" do
    context "when the archiver has written this model before" do
      before(:each) do
        allow(archiver).to receive(:seen?)
          .with("repository", "http://hostname.com/path")
          .and_return(true)
      end

      it "does not write the model" do
        expect(archiver).to_not receive(:write)
        expect(archiver).to_not receive(:seen)
        expect(pseudo_exporter.serialize("repository", pseudo_model)).to eq(false)
      end
    end

    context "when the archiver has not written this model before" do
      before(:each) do
        allow(archiver).to receive(:seen?)
          .with("repository", "http://hostname.com/path")
          .and_return(false)
      end

      it "does writes the model" do
        expect(serializer).to receive(:serialize)
        expect(archiver).to receive(:write)
        expect(archiver).to receive(:seen).with("repository", "http://hostname.com/path")
        expect(pseudo_exporter.serialize("repository", pseudo_model)).to eq(true)
      end
    end

    context "when the model cannot be serialized" do
      it "returns false" do
        expect(pseudo_exporter.serialize("user", nil)).to eq(false)
      end

      it "logs an error" do
        expect(pseudo_exporter.current_export.logger).to receive(:error).with(
          "user:  could not be serialized"
        )

        pseudo_exporter.serialize("user", nil)
      end
    end

    context "when the model is an attachment" do
      # A single GitLab upload can be referenced from multiple places (issue
      # body, comments, merge request body, ...). Each occurrence is given a
      # distinct archive_path by Attachable, so dedup-by-url must NOT collapse
      # them — otherwise later occurrences end up pointing at a file the
      # importer has already consumed and deleted.
      let(:attachment_serializer) { double GlExporter::AttachmentSerializer }
      let(:attachment_model) do
        {
          "type"         => "issue",
          "model"        => pseudo_model,
          "repository"   => { "web_url" => "http://hostname.com/path" },
          "attach_path"  => "/uploads/abc/file.png",
          "archive_path" => "/uploads/abc/1_file.png",
        }
      end

      before(:each) do
        allow(GlExporter::AttachmentSerializer).to receive(:new).and_return(attachment_serializer)
        allow(attachment_serializer).to receive(:serialize)
        allow(archiver).to receive(:write)
        allow(archiver).to receive(:seen)
      end

      it "writes the record even when the same url has been seen before" do
        allow(archiver).to receive(:seen?).and_return(true)

        expect(archiver).to receive(:write).twice
        expect(pseudo_exporter.serialize("attachment", attachment_model)).to eq(true)
        expect(pseudo_exporter.serialize("attachment", attachment_model)).to eq(true)
      end
    end
  end
end
