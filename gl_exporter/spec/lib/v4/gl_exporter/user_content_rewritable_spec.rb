# frozen_string_literal: true
require "spec_helper"

describe GlExporter::UserContentRewritable, :v4 do
  let(:pseudo_exporter) { PseudoExporter.new(pseudo_model) }

  let(:pseudo_model) do
    PseudoModel.new.tap do |model|
      model["note"] = body_content
    end
  end

  let(:body_content) { "lorem ipsum" }

  let(:project_exporter) { GlExporter::ProjectExporter.new(project) }

  let(:project) do
    VCR.use_cassette("v4/gitlab-projects/Mouse-Hack/hugo-pages") do
      Gitlab.project("Mouse-Hack", "hugo-pages")
    end
  end

  before(:each) do
    PseudoExporter.include(GlExporter::UserContentRewritable)
    allow(pseudo_exporter).to receive(:project_exporter).and_return(project_exporter)
  end

  describe "#rewrite_user_content!" do
    it "detects the correct body key" do
      expect(pseudo_exporter).to receive(:rewrite_numeric_mentions)
        .with("note")
      pseudo_exporter.rewrite_user_content!
    end

    it "strips Kramdown image attribute lists" do
      expect(pseudo_exporter).to receive(:rewrite_kramdown_image_attributes)
        .with("note")
      pseudo_exporter.rewrite_user_content!
    end
  end

  describe "#rewrite_kramdown_image_attributes" do
    context "with a resized inline image" do
      let(:body_content) do
        "before ![diagram](/uploads/abc123/x.png){width=900 height=522} after"
      end

      it "removes the trailing Kramdown IAL but keeps the image" do
        pseudo_exporter.rewrite_kramdown_image_attributes("note")
        expect(pseudo_model["note"])
          .to eq("before ![diagram](/uploads/abc123/x.png) after")
      end
    end

    context "with an absolute image url" do
      let(:body_content) do
        "![diagram](https://gitlab.example.com/uploads/abc/x.png){width=120 height=80}"
      end

      it "removes the IAL regardless of url form" do
        pseudo_exporter.rewrite_kramdown_image_attributes("note")
        expect(pseudo_model["note"])
          .to eq("![diagram](https://gitlab.example.com/uploads/abc/x.png)")
      end
    end

    context "with multiple images in one body" do
      let(:body_content) do
        "![a](/uploads/1/a.png){width=10} text ![b](/uploads/2/b.png){width=20 height=30}"
      end

      it "strips every image's IAL" do
        pseudo_exporter.rewrite_kramdown_image_attributes("note")
        expect(pseudo_model["note"])
          .to eq("![a](/uploads/1/a.png) text ![b](/uploads/2/b.png)")
      end
    end

    context "with braces that do not follow an image" do
      let(:body_content) { "plain text {width=900 height=522} and `code {x=1}`" }

      it "leaves unrelated braces untouched" do
        pseudo_exporter.rewrite_kramdown_image_attributes("note")
        expect(pseudo_model["note"])
          .to eq("plain text {width=900 height=522} and `code {x=1}`")
      end
    end

    context "with an image that has no IAL" do
      let(:body_content) { "![plain](/uploads/abc/x.png)" }

      it "leaves the image untouched" do
        pseudo_exporter.rewrite_kramdown_image_attributes("note")
        expect(pseudo_model["note"]).to eq("![plain](/uploads/abc/x.png)")
      end
    end
  end

  describe "#rewrite_numeric_mentions" do
    let(:body_content) do
      "This is a merge: !1001, issue: #123, notthis!321 or#585this "
    end

    it "detects merge request and issue mentions" do
      expect(pseudo_exporter).to receive(:translate_id).with("!", "1001")
      expect(pseudo_exporter).to receive(:translate_id).with("#", "123")
      expect(pseudo_exporter).to_not receive(:translate_id).with("!", "321")
      expect(pseudo_exporter).to_not receive(:translate_id).with("#", "585")
      pseudo_exporter.rewrite_numeric_mentions("note")
    end
  end

  describe "#translate_id" do
    before(:each) do
      project_exporter.rewritten_ids[:merge_requests] = {
        10 => 30,
        20 => 1,
        21 => 2,
        22 => 5,
      }
      project_exporter.rewritten_ids[:issues] = {
        10 => 20,
        18 => 3,
        19 => 4,
        23 => 6,
      }
    end

    it "translates merge request ids" do
      expect(pseudo_exporter.translate_id("!", "10")).to eq("30")
      expect(pseudo_exporter.translate_id("!", "20")).to eq("1")
      expect(pseudo_exporter.translate_id("!", "21")).to eq("2")
      expect(pseudo_exporter.translate_id("!", "22")).to eq("5")
      expect(pseudo_exporter.translate_id("!", "34")).to eq("34")
    end

    it "translates issue ids" do
      expect(pseudo_exporter.translate_id("#", "10")).to eq("20")
      expect(pseudo_exporter.translate_id("#", "18")).to eq("3")
      expect(pseudo_exporter.translate_id("#", "19")).to eq("4")
      expect(pseudo_exporter.translate_id("#", "23")).to eq("6")
      expect(pseudo_exporter.translate_id("#", "34")).to eq("34")
    end
  end
end
