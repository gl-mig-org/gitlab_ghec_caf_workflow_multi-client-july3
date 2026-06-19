# frozen_string_literal: true
require "spec_helper"
require "gl_exporter/tar_utils"
require "digest/md5"

describe GlExporter::ArchiveBuilder, :v4 do
  include GlExporter::TarUtils

  subject(:archive_builder) { described_class.new }
  let(:tarball_path) { Tempfile.new("string").path }
  let(:files) { `tar tfz #{tarball_path}`.split }

  def file_md5sum(path)
    Digest::MD5.file(path).hexdigest # rubocop:disable GitHub/InsecureHashAlgorithm
  end

  it "makes a tarball with a json file" do
    archive_builder.write(model_name: "mouse", data: { "foo" => "bar" })
    archive_builder.create_tar(tarball_path)

    expect(files).to include("./mice_000001.json")
  end

  it "adds a schema.json" do
    archive_builder.create_tar(tarball_path)

    expect(files).to include("./schema.json")

    dir = Dir.mktmpdir "archive_builder"

    extract_archive(tarball_path, dir) do
      path = File.join(dir, "schema.json")
      json_data = File.read(path)
      expect(JSON.load(json_data)).to eq({ "version" => "1.2.0" })
    end
  end

  it "adds a urls.json" do
    archive_builder.create_tar(tarball_path)

    expect(files).to include("./urls.json")
  end

  context "with a repository in a subgroup" do
    let(:project) do
      VCR.use_cassette("v4/gitlab-projects/Mouse-Hack/subgroup1/repo1") do
        Gitlab.project("Mouse-Hack/subgroup1", "repo1")
      end
    end

    it "calls #archive_repo to clone to a directory with the group and subgroups joined by hyphens" do
      expect(archive_builder).to receive(:archive_repo).with(
        clone_url: "https://gitlab.com/Mouse-Hack/subgroup1/repo1.git",
        to: "#{archive_builder.staging_dir}/repositories/Mouse-Hack-subgroup1/repo1.git",
        credentials: be_a(Rugged::Credentials::UserPassword)
      )

      archive_builder.clone_repo(project)
    end
  end

  describe "#clone_wiki" do
    let(:project) do
      VCR.use_cassette("v4/gitlab-projects/Mouse-Hack/hugo-pages") do
        Gitlab.project("Mouse-Hack", "hugo-pages")
      end
    end

    let(:wiki_fixture_path) { "spec/fixtures/repositories/Mouse-Hack/hugo-pages.wiki.git" }
    let(:rugged_wiki) { Rugged::Repository.new(wiki_fixture_path) }

    it "clones the wiki information" do
      expect(archive_builder).to receive(:archive_repo).with(
        clone_url: "https://gitlab.com/Mouse-Hack/hugo-pages.wiki.git",
        to: "#{archive_builder.staging_dir}/repositories/Mouse-Hack/hugo-pages.wiki.git",
        credentials: be_a(Rugged::Credentials::UserPassword)
      ).and_return(rugged_wiki)

      archive_builder.clone_wiki(project)
    end

    context "with a repository in a subgroup" do
      let(:project) do
        VCR.use_cassette("v4/gitlab-projects/Mouse-Hack/subgroup1/repo1") do
          Gitlab.project("Mouse-Hack/subgroup1", "repo1")
        end
      end

      it "calls #archive_repo to clone to a directory with the group and subgroups joined by hyphens" do
        expect(archive_builder).to receive(:archive_repo).with(
          clone_url: "https://gitlab.com/Mouse-Hack/subgroup1/repo1.wiki.git",
          to: "#{archive_builder.staging_dir}/repositories/Mouse-Hack-subgroup1/repo1.wiki.git",
          credentials: be_a(Rugged::Credentials::UserPassword)
        ).and_return(rugged_wiki)

        archive_builder.clone_wiki(project)
      end
    end

    context "when wiki head ref is master" do
      before(:each) { allow(archive_builder).to receive(:archive_repo).and_return(rugged_wiki) }

      it "does not attempt to change the head ref to master" do
        expect(rugged_wiki.branches).to_not receive(:rename)

        archive_builder.clone_wiki(project)
      end
    end

    context "when wiki head ref not master" do
      let(:wiki_fixture_path) { "spec/fixtures/repositories/Mouse-Hack/wiki-with-main-branch.wiki.git" }

      before(:each) { allow(archive_builder).to receive(:archive_repo).and_return(rugged_wiki) }

      it "changes the head ref to master" do
        expect(rugged_wiki.branches).to receive(:rename).with("main", "master")

        archive_builder.clone_wiki(project)
      end
    end
  end

  describe "#save_attachment" do
    context "with an existing attachment" do
      subject(:save_attachment) do
        VCR.use_cassette("v4/remote-attachment") do
          archive_builder.save_attachment("test.png", "http://httpstat.us/200")
        end
      end

      it { is_expected.to  eq(true) }

      context "with SSL verification disabled", :vcr do
        around do |example|
          with_ssl_verify(false) { example.run }
        end

        it "ignores SSL errors" do
          archive_builder.save_attachment("tmp/test.png", "https://self-signed.badssl.com/")
        end
      end

      context "with SSL verification enabled", :vcr do
        around do |example|
          with_ssl_verify(true) { example.run }
        end

        it "raises SSL errors" do
          expect {
            archive_builder.save_attachment("tmp/test.png", "https://self-signed.badssl.com/")
          }.to raise_error(Faraday::SSLError)
        end
      end
    end

    context "with a unicode attachment" do
      subject(:save_attachment) do
        VCR.use_cassette("v4/remote-attachment-unicode") do
          archive_builder.save_attachment("test.png", "https://placehold.it/400?text=")
        end
      end

      it { is_expected.to  eq(true) }
    end

    context "with valid attachment download", :vcr do
      let(:staging_dir) { Dir.mktmpdir "archive_builder" }
      let(:expected_md5sum) { "b3341d1acf8ac1cf833debf0d265dbe4" }
      let(:file_name) { "1x1.png" }
      let(:attachment_path) { File.join(staging_dir, "attachments", file_name) }

      subject(:save_attachment) do
        archive_builder.save_attachment(file_name, "https://placehold.it/1")
      end

      it { is_expected.to  eq(true) }

      it "saves attachment content to disk" do
        allow_any_instance_of(
          GlExporter::ArchiveBuilder
        ).to receive(:staging_dir).and_return(staging_dir)

        subject

        expect(file_md5sum(attachment_path)).to eq(expected_md5sum)
      end
    end

    context "with a missing attachment" do
      subject(:save_attachment) do
        VCR.use_cassette("v4/remote-attachment-404") do
          archive_builder.save_attachment("test.png", "http://httpstat.us/404")
        end
      end

      it { is_expected.to  eq(false) }
    end

    context "with an erroneous attachment" do
      subject(:save_attachment) do
        VCR.use_cassette("v4/remote-attachment-422") do
          archive_builder.save_attachment("test.png", "http://httpstat.us/422")
        end
      end

      it { is_expected.to  eq(false) }
    end

    # On GitLab < 17.4 the download falls back to the web `<repo>/uploads/...`
    # route, which is not authenticated by PRIVATE-TOKEN and answers with a 302
    # redirect to the sign-in page. Faraday's :raise_error middleware ignores
    # 3xx and the connection does not follow redirects, so without an explicit
    # guard the "You are being redirected" login HTML would be written to the
    # tarball as if it were the asset. The download must fail instead.
    context "when the response is an unauthenticated redirect (302)" do
      let(:staging_dir) { Dir.mktmpdir "archive_builder" }
      let(:save_path) { File.join(staging_dir, "attachments", "test.png") }
      let(:redirect_response) do
        instance_double(
          Faraday::Response,
          success?: false,
          status: 302,
          body: "<html><body>You are being <a href=\"/users/sign_in\">redirected</a>.</body></html>"
        )
      end

      before do
        allow_any_instance_of(GlExporter::ArchiveBuilder)
          .to receive(:staging_dir).and_return(staging_dir)
        allow(Gitlab).to receive_message_chain(:connection, :get)
          .and_return(redirect_response)
      end

      subject(:save_attachment) do
        archive_builder.save_attachment(
          "test.png",
          "https://gitlab.example.com/group/proj/uploads/abc123/test.png",
          "https://gitlab.example.com/group/proj/issues/1"
        )
      end

      it { is_expected.to eq(false) }

      it "does not write the redirect HTML to disk as the asset" do
        subject
        expect(File.exist?(save_path)).to eq(false)
      end
    end

    context "with a Faraday::ClientError" do
      subject(:save_attachment) do
        archive_builder.save_attachment("Sample.pdf", "http://httpstat.us/302", "https://gitlab.com/Mouse-Hack/hugo-pages/issues/5#note_11735615")
      end
      let(:logger_double) { instance_double(Logger) }

      before do
        allow(Gitlab).to receive_message_chain(:connection, :get) { raise Faraday::ClientError.new("message") }
      end

      it "logs an error to the output via current_export" do
        allow(archive_builder.current_export).to receive(:output_logger) { logger_double }
        expect(logger_double).to receive(:error)
        subject
      end

      it "logs an error to the log via current_export" do
        allow(archive_builder.current_export).to receive(:logger) { logger_double }
        expect(logger_double).to receive(:error)
        subject
      end
    end

    context "with an invalid URL" do
      subject(:save_attachment) do
        archive_builder.save_attachment("test.png", "http://in valid-url")
      end
      let(:logger_double) { instance_double(Logger) }

      it "does not raise an error" do
        expect { subject }.to_not raise_error
      end

      it "logs an error to the output via current_export" do
        allow(archive_builder.current_export).to receive(:output_logger) { logger_double }
        expect(logger_double).to receive(:error).with("Could not download asset at http://in valid-url because it is not a valid URL")
        subject
      end

      it "logs an error to the log via current_export" do
        allow(archive_builder.current_export).to receive(:logger) { logger_double }
        expect(logger_double).to receive(:error).with("Could not download asset at http://in valid-url because it is not a valid URL")
        subject
      end
    end
  end

  describe "#next_attachment_counter" do
    it "starts at 1 and increments monotonically" do
      expect([
        archive_builder.next_attachment_counter,
        archive_builder.next_attachment_counter,
        archive_builder.next_attachment_counter,
      ]).to eq([1, 2, 3])
    end
  end
end
