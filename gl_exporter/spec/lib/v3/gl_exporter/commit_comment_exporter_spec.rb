# frozen_string_literal: true
require "spec_helper"

describe GlExporter::CommitCommentExporter, :v3 do
  let(:commit_comment_exporter) do
    VCR.use_cassette("v3/gl_exporter/commit_comment_exporter") do
      GlExporter::CommitCommentExporter.new(
        commit,
        commit_comment,
        project_exporter: project_exporter,
      )
    end
  end

  let(:project_exporter) { GlExporter::ProjectExporter.new(project) }

  let(:commit) do
    VCR.use_cassette("v3/gitlab-commit") do
      Gitlab.commit(1169162, "220d5dc2582a49d694c503abdb8cf25bcdd81dce")
    end
  end

  let(:commit_comment) do
    VCR.use_cassette("v3/gitlab-commit_comment") do
      Gitlab.commit_comments(1169162, "220d5dc2582a49d694c503abdb8cf25bcdd81dce").first
    end
  end

  let(:project) do
    VCR.use_cassette("v3/gitlab-projects/Mouse-Hack/hugo-pages") do
      Gitlab.project("Mouse-Hack", "hugo-pages")
    end
  end

  describe "#model" do
    it "aliases to the commit comment" do
      expect(commit_comment_exporter.model).to eq(commit_comment)
    end
  end

  describe "#project" do
    it "returns the project from the project_exporter" do
      expect(commit_comment_exporter.project).to eq(project)
    end
  end

  describe "#created_at" do
    it "returns the timestamp of when the commit comment was created" do
      expect(commit_comment_exporter.created_at).to eq("2016-05-10T22:23:50.501Z")
    end
  end

  describe "rewrite!" do
    it "should call `#rewrite_user_content!`" do
      expect(commit_comment_exporter).to receive(:rewrite_user_content!)
      commit_comment_exporter.rewrite!
    end
  end

  describe "#export" do
    it "should serialize the model and extract attachments" do
      expect(commit_comment_exporter).to receive(:extract_attachments)
        .with("commit_comment", commit_comment)
      expect(commit_comment_exporter).to receive(:serialize)
        .with("commit_comment", commit_comment)
      commit_comment_exporter.export
    end
  end

  describe "#normalize_commit_comment" do
    it "returns the hash unchanged when input is a Hash" do
      raw = { "note" => "hi" }
      expect(exporter.normalize_commit_comment(raw)).to eq(raw)
    end

    it "parses a valid JSON string into a hash" do
      raw = '{"note":"hello"}'
      result = exporter.normalize_commit_comment(raw)
      expect(result).to eq({ "note" => "hello" })
    end

    it "logs and raises ArgumentError for an invalid JSON string" do
      raw = "{not valid json}"
      expect {
        exporter.normalize_commit_comment(raw)
      }.to raise_error(ArgumentError, /Commit comment not JSON/)
      expect(exporter.logger).to have_received(:error).with(/Commit comment not JSON/)
    end

    it "logs and raises ArgumentError for non-hash, non-string types" do
      raw = 123
      expect {
        exporter.normalize_commit_comment(raw)
      }.to raise_error(ArgumentError, /Commit comment not JSON/)
      expect(exporter.logger).to have_received(:error).with(/Commit comment not JSON/)
    end
  end
end
