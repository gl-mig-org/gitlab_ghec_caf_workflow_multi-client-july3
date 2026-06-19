# frozen_string_literal: true
require "spec_helper"

describe GlExporter::Attachable, :v3 do
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
    allow(archiver).to receive(:save_attachment).and_return(true)
    allow(pseudo_exporter).to receive(:serialize)
  end

  describe "#extract_attachments" do
    it "extracts images from the text" do
      expect(pseudo_exporter).to receive(:serialize).with(
        "attachment",
        {
          "type"        => "issue",
          "model"       => pseudo_model,
          "repository"  => project,
          "attach_path" => "/uploads/4c34b72a41b3e1b2f9a97fd0c2e50d82/image.png"
        }
      )

      pseudo_exporter.extract_attachments("issue", pseudo_model)
    end

    it "extracts attachments from the text" do
      expect(pseudo_exporter).to receive(:serialize).with(
        "attachment",
        {
          "type"        => "issue",
          "model"       => pseudo_model,
          "repository"  => project,
          "attach_path" => "/uploads/aca2cc60c183e113481adbdd167aa9fe/pdf-sample.pdf"
        }
      )

      pseudo_exporter.extract_attachments("issue", pseudo_model)
    end

    it "extracts inline attachments from the text" do
      expect(pseudo_exporter).to receive(:serialize).with(
        "attachment",
        {
          "type"        => "issue",
          "model"       => pseudo_model,
          "repository"  => project,
          "attach_path" => "/uploads/6323ffc765d5e4ae138992687096851b/image.png"
        }
      )

      pseudo_exporter.extract_attachments("issue", pseudo_model)
    end

    context "with erroneous atatchments" do
      before do
        allow(archiver).to receive(:save_attachment).and_return(false)
      end

      it "will not serialize attachments" do
        expect(pseudo_exporter).to_not receive(:serialize)

        pseudo_exporter.extract_attachments("issue", pseudo_model)
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
  end
end
