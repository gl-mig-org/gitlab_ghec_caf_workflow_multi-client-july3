# frozen_string_literal: true
require "spec_helper"

describe GlExporter::Attachable, :v4 do
  let(:pseudo_exporter) { PseudoExporter.new(pseudo_model) }

  let(:pseudo_model) do
    PseudoModel.new.tap do |model|
      model["note"] = body_content
      model["iid"] = 55
      model["repository"] = {
        "web_url" => "https://gitlab.com/Mouse-Hack/hugo-pages"
      }
    end
  end

  let(:body_content) do <<-'EOS'
Here is my issue

![image](/uploads/4c34b72a41b3e1b2f9a97fd0c2e50d82/image.png)

[pdf-sample.pdf](/uploads/aca2cc60c183e113481adbdd167aa9fe/pdf-sample.pdf)

![image](/uploads/6323ffc765d5e4ae138992687096851b/image.png) for **manually added deal**** in the Deal Management (***"SourceType":6***,"SourceName":"<script>alert(\"This is XSS vulnerability\")</script>","**ManualDealId****":"<script>alert(\"This is XSS vulnerability\")</script>"
EOS
  end

  let(:project) { double Hash }

  let(:archiver) { double GlExporter::ArchiveBuilder }

  before(:each) do
    PseudoExporter.include(GlExporter::Attachable)
    allow(pseudo_exporter).to receive(:archiver).and_return(archiver)
    allow(pseudo_exporter).to receive(:project).and_return(project)
    allow(project).to receive(:[]).with("web_url").and_return("http://hostname.com/path")
    allow(project).to receive(:[]).with("namespace").and_return("path")
    allow(project).to receive(:[]).with("path_with_namespace").and_return("Mouse-Hack/hugo-pages")
    # `id` is consumed by Attachable#attachment_download_url to build the
    # authenticated /api/v4/projects/<id>/uploads/... endpoint.
    allow(project).to receive(:[]).with("id").and_return(1169162)
    allow(archiver).to receive(:save_attachment).and_return(true)
    # extract_attachments now consults Gitlab.project_uploads_api_available? to pick
    # the download URL form; default it on so these cases exercise the API path
    # without making a live GET /version request. The #attachment_download_url
    # describe block overrides this per-context to cover the fallback.
    allow(Gitlab).to receive(:project_uploads_api_available?).and_return(true)
    # Drive a real monotonic counter rather than stubbing a constant; lets
    # tests observe per-occurrence archive paths (1_file.png, 2_file.png, ...).
    @attachment_counter = 0
    allow(archiver).to receive(:next_attachment_counter) { @attachment_counter += 1 }
    allow(pseudo_exporter).to receive(:serialize)
  end

  describe "#extract_attachments" do
    # The shared body_content has three distinct uploads, so the counter walks
    # 1 -> 2 -> 3 across them in source order: image.png, pdf-sample.pdf, image.png.
    it "extracts images from the text" do
      expect(pseudo_exporter).to receive(:serialize).with(
        "attachment",
        {
          "type" => "issue",
          "model" => pseudo_model,
          "repository" => project,
          "attach_path" => "/uploads/4c34b72a41b3e1b2f9a97fd0c2e50d82/image.png",
          "archive_path" => "/uploads/4c34b72a41b3e1b2f9a97fd0c2e50d82/1_image.png",
        }
      )

      pseudo_exporter.extract_attachments("issue", pseudo_model)
    end

    it "extracts attachments from the text" do
      expect(pseudo_exporter).to receive(:serialize).with(
        "attachment",
        {
          "type" => "issue",
          "model" => pseudo_model,
          "repository" => project,
          "attach_path" => "/uploads/aca2cc60c183e113481adbdd167aa9fe/pdf-sample.pdf",
          "archive_path" => "/uploads/aca2cc60c183e113481adbdd167aa9fe/2_pdf-sample.pdf",
        }
      )

      pseudo_exporter.extract_attachments("issue", pseudo_model)
    end

    it "extracts inline attachments from the text" do
      expect(pseudo_exporter).to receive(:serialize).with(
        "attachment",
        {
          "type" => "issue",
          "model" => pseudo_model,
          "repository" => project,
          "attach_path" => "/uploads/6323ffc765d5e4ae138992687096851b/image.png",
          "archive_path" => "/uploads/6323ffc765d5e4ae138992687096851b/3_image.png",
        }
      )

      pseudo_exporter.extract_attachments("issue", pseudo_model)
    end

    context "with backslashes in the text" do
      let(:body_content) do <<-'EOS'
        [Here's an attachment](/uploads/abc123/image\_with\_backslashes.png)
        EOS
      end

      it "is robust against backslashes in the attach_path" do
        expect(pseudo_exporter).to receive(:serialize).with(
          "attachment",
          {
            "type" => "issue",
            "model" => pseudo_model,
            "repository" => project,
            "attach_path" => "/uploads/abc123/image_with_backslashes.png",
            "archive_path" => "/uploads/abc123/1_image_with_backslashes.png",
          }
        )

        pseudo_exporter.extract_attachments("issue", pseudo_model)
      end
    end

    context "with erroneous atatchments" do
      before do
        allow(archiver).to receive(:save_attachment).and_return(false)
      end

      it "will not serialize attachments" do
        expect(pseudo_exporter).to_not receive(:serialize)

        pseudo_exporter.extract_attachments("issue", pseudo_model)
      end

      it "preserves the original attachment markdown in the body" do
        pseudo_exporter.extract_attachments("issue", pseudo_model)
        expect(pseudo_model["note"]).to eq(body_content)
      end
    end

    context "when save_attachment raises an exception" do
      let(:logger) { double("logger") }
      let(:output_logger) { double("output_logger") }
      let(:current_export) { double("current_export") }

      before do
        allow(pseudo_exporter).to receive(:current_export).and_return(current_export)
        allow(current_export).to receive(:logger).and_return(logger)
        allow(current_export).to receive(:output_logger).and_return(output_logger)
        allow(logger).to receive(:error)
        allow(output_logger).to receive(:error)
        allow(archiver).to receive(:save_attachment).and_raise(URI::InvalidURIError.new("bad URI(is not URI?): \"https://example.com/...\""))
      end

      it "logs the error and continues processing" do
        expect(logger).to receive(:error).with(/Failed to extract attachment in issue #55.*Mouse-Hack\/hugo-pages.*\/uploads\/4c34b72a41b3e1b2f9a97fd0c2e50d82\/image\.png.*fix the attachment reference at the source/)
        expect(output_logger).to receive(:error).with(/Failed to extract attachment in issue #55.*Mouse-Hack\/hugo-pages.*\/uploads\/4c34b72a41b3e1b2f9a97fd0c2e50d82\/image\.png.*fix the attachment reference at the source/)

        # Should not raise an exception
        expect { pseudo_exporter.extract_attachments("issue", pseudo_model) }.not_to raise_error

        # Should return the original text with attachment references intact
        result = pseudo_exporter.extract_attachments("issue", pseudo_model)
        expect(pseudo_model["note"]).to include("[image](/uploads/4c34b72a41b3e1b2f9a97fd0c2e50d82/image.png)")
      end
    end

    context "when save_attachment raises an exception with malformed markdown" do
      let(:malformed_body_content) do
        "[specs.docx](/uploads/b573c75d126c851abdc3233![image1](/uploads/b39ee40b3690dcdb74922d5877c6b7f6/image1.JPG)\n\n![image2](/uploads/aed35b01b989d2749edd95979b8c77ce/image2.JPG)\n\n![image13](/uploads/bb3ea9e782b2e2d98635989ee35a6a43/image3.JPG)6ca0ab04f/specs.docx)"
      end

      let(:malformed_pseudo_model) do
        PseudoModel.new.tap do |model|
          model["note"] = malformed_body_content
          model["iid"] = 99
          model["title"] = "Malformed attachment test"
          model["repository"] = {
            "web_url" => "https://gitlab.com/Test/malformed-test"
          }
        end
      end

      let(:logger) { double("logger") }
      let(:output_logger) { double("output_logger") }
      let(:current_export) { double("current_export") }

      before do
        allow(pseudo_exporter).to receive(:current_export).and_return(current_export)
        allow(current_export).to receive(:logger).and_return(logger)
        allow(current_export).to receive(:output_logger).and_return(output_logger)
        allow(logger).to receive(:error)
        allow(output_logger).to receive(:error)
        allow(archiver).to receive(:save_attachment).and_raise(URI::InvalidURIError.new("bad URI(is not URI?): malformed URL with truncation..."))
      end

      it "handles malformed markdown with nested attachments and logs detailed errors" do
        # Should log errors for each valid attachment pattern found
        expect(logger).to receive(:error).with(/Failed to extract attachment in issue #99.*'Malformed attachment test'.*Mouse-Hack\/hugo-pages.*fix the attachment reference at the source/).at_least(:once)
        expect(output_logger).to receive(:error).with(/Failed to extract attachment in issue #99.*'Malformed attachment test'.*Mouse-Hack\/hugo-pages.*fix the attachment reference at the source/).at_least(:once)

        # Should not raise an exception despite malformed URLs
        expect { pseudo_exporter.extract_attachments("issue", malformed_pseudo_model) }.not_to raise_error

        # Should preserve original text including malformed parts
        result = pseudo_exporter.extract_attachments("issue", malformed_pseudo_model)
        expect(malformed_pseudo_model["note"]).to include("image1.JPG")
        expect(malformed_pseudo_model["note"]).to include("image2.JPG")
        expect(malformed_pseudo_model["note"]).to include("image3.JPG")
      end
    end

    context "with problematic attachment regex cases" do
      let(:body_content_with_issue) do <<-'EOS'
[https://example.com/example-organization/example-repository/uploads
/869b64d84a3ee3b6e0bcec46de5cee89/file![example-text](/uploads/4b302713e671281d63e82bd3621cdd7b/file.png)
EOS
      end

      let(:pseudo_model_with_issue) do
        PseudoModel.new.tap do |model|
          model["note"] = body_content_with_issue
          model["iid"] = 55
          model["repository"] = {
            "web_url" => "https://gitlab.com/Mouse-Hack/hugo-pages"
          }
        end
      end

      it "should not capture text across newlines and invalid content" do
        # The fixed regex should only capture the valid attachment pattern, not the full problematic string
        expect(pseudo_exporter).to receive(:serialize).with(
          "attachment",
          {
            "type" => "issue",
            "model" => pseudo_model_with_issue,
            "repository" => project,
            "attach_path" => "/uploads/4b302713e671281d63e82bd3621cdd7b/file.png",
            "archive_path" => "/uploads/4b302713e671281d63e82bd3621cdd7b/1_file.png",
          }
        )

        # This should not raise a URI::InvalidURIError
        expect { pseudo_exporter.extract_attachments("issue", pseudo_model_with_issue) }.not_to raise_error
      end
    end

    context "regression: commit_comment URL stability across body mutation" do
      # extract_attachments rewrites the model's body in-place. The
      # commit_comment URL is derived (via ModelUrlService#fake_id) from the
      # model's contents, so if the body were part of that hash the URL would
      # silently change between the moment the attachment record captures its
      # parent_url and the moment writable.rb serializes the commit_comment
      # itself. Attachment records would then point at a URL no comment
      # owns, and the importer would drop every inline attachment on commit
      # comments. This test pins the invariant: the URL must be stable.
      let(:body_content) { "[doc](/uploads/abc123/file.pdf)" }

      let(:commit_comment_model) do
        PseudoModel.new.tap do |model|
          model["note"]       = body_content
          model["created_at"] = "2024-01-01T00:00:00Z"
          model["author"]     = { "id" => 1, "username" => "alice" }
          model["commit"]     = { "id" => "deadbeefcafef00d" }
          model["repository"] = { "web_url" => "https://gitlab.com/Mouse-Hack/hugo-pages" }
        end
      end

      let(:url_service) { GlExporter::ModelUrlService.new }

      it "computes the same commit_comment URL before and after the body is rewritten" do
        url_before = url_service.url_for_model(commit_comment_model, type: "commit_comment")

        pseudo_exporter.extract_attachments("commit_comment", commit_comment_model)

        # Sanity check: the body really was mutated by extract_attachments.
        expect(commit_comment_model["note"]).not_to eq(body_content)

        url_after = url_service.url_for_model(commit_comment_model, type: "commit_comment")
        expect(url_after).to eq(url_before)
      end
    end

    context "with the same upload referenced multiple times in one body" do
      # Drives the next_attachment_counter contract: the importer consumes
      # each archive entry once and deletes the file after upload, so the
      # exporter has to write N distinct files when the same /uploads/...
      # path appears in N places.
      let(:body_content) do
        "[first](/uploads/abc/file.png)\n[second](/uploads/abc/file.png)\n[third](/uploads/abc/file.png)"
      end

      it "produces a distinct archive_path for each occurrence" do
        archive_paths = []
        allow(pseudo_exporter).to receive(:serialize) do |_type, tmp|
          archive_paths << tmp["archive_path"]
        end

        pseudo_exporter.extract_attachments("issue", pseudo_model)

        expect(archive_paths).to eq([
          "/uploads/abc/1_file.png",
          "/uploads/abc/2_file.png",
          "/uploads/abc/3_file.png",
        ])
      end
    end
  end

  describe "#attachment_download_url (private)" do
    before(:each) { allow(Gitlab).to receive(:api_endpoint).and_return("https://gitlab.com/api/v4") }

    context "when the instance exposes the uploads download API (>= 17.4)" do
      before(:each) { allow(Gitlab).to receive(:project_uploads_api_available?).and_return(true) }

      it "uses the authenticated /api/v4/projects/<id>/uploads/ endpoint" do
        url = pseudo_exporter.send(:attachment_download_url, project, "/uploads/abc/file.png")
        expect(url).to eq("https://gitlab.com/api/v4/projects/1169162/uploads/abc/file.png")
      end

      it "falls back to the legacy web URL when the project has no id" do
        allow(project).to receive(:[]).with("id").and_return(nil)
        url = pseudo_exporter.send(:attachment_download_url, project, "/uploads/abc/file.png")
        expect(url).to eq("http://hostname.com/path/uploads/abc/file.png")
      end

      it "falls back to the legacy web URL when attach_path has no filename" do
        url = pseudo_exporter.send(:attachment_download_url, project, "/uploads/abc")
        expect(url).to eq("http://hostname.com/path/uploads/abc")
      end
    end

    context "when the instance is too old for the uploads download API (< 17.4)" do
      before(:each) { allow(Gitlab).to receive(:project_uploads_api_available?).and_return(false) }

      it "falls back to the legacy web URL even when the project has an id" do
        url = pseudo_exporter.send(:attachment_download_url, project, "/uploads/abc/file.png")
        expect(url).to eq("http://hostname.com/path/uploads/abc/file.png")
      end
    end
  end
end
