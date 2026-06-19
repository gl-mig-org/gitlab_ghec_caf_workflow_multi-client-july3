# frozen_string_literal: true
class GlExporter

  # Serializes Attachments from a temporary model
  #
  # #### Model Example:
  #
  # ```
  # {
  #   "type"        => "issue",
  #   "model"       => GITLAB_ISSUE,
  #   "repository"  => GITLAB_PROJECT,
  #   "attach_path" => "/uploads/9ac59438bec5a5e130f6c5c502a34713/image.png",
  # }
  # ```
  class AttachmentSerializer < BaseSerializer

    # @see GlExporter::BaseSerializer#to_gh_hash
    def to_gh_hash
      {
        :type => "attachment",
        :url => url,
        parent_type.to_sym => parent_url,
        :user => user,
        :asset_name => asset_name,
        :asset_content_type => content_type,
        :asset_url => local_asset_url,
        # Importer schema uses :created_date for attachments (mirrors
        # gh-gl2gh-legacy/src/gl2gh/Services/GlSerializer.cs SerializeAttachment).
        # Emitting :created_at causes the importer to silently drop the record.
        :created_date => created_at,
      }
    end

    private

    def user
      url_for_model(gl_model["model"]["author"])
    end

    def url
      url_for_model(gl_model, type: "attachment")
    end

    def attach_path
      gl_model["attach_path"]
    end

    def parent_type
      gl_model["type"]
    end

    def parent_url
      url_for_model(gl_model["model"], type: parent_type)
    end

    def asset_name
      File.basename(attach_path)
    end

    # Infer the MIME type from the file name. GitLab's upload endpoint always
    # returns `application/octet-stream` from HEAD requests, which makes the
    # importer wrap non-image attachments as `.zip` blobs and skip inline
    # rendering for images, so we let Marcel infer a real type from the
    # extension instead.
    def content_type
      Marcel::MimeType.for(name: attach_path)
    end

    def token
      Gitlab.token
    end

    def local_asset_url
      File.join("tarball://root/attachments/", gl_model["archive_path"] || attach_path)
    end

    def created_at
      gl_model["model"]["created_at"]
    end
  end
end
