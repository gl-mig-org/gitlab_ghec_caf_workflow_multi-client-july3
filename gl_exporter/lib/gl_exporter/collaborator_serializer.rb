# frozen_string_literal: true
class GlExporter
  # MINIMAL   = 5  (upgraded to GUEST)
  # GUEST     = 10
  # PLANNER   = 15 (downgraded to GUEST)
  # REPORTER  = 20
  # DEVELOPER = 30
  # MASTER    = 40
  # OWNER     = 50
  PERMISSION_MAP = {
    5 => "read", # Minimal access -> Guest (upgraded)
    10 => "read",
    15 => "read", # Planner -> Guest (downgraded)
    20 => "triage",
    30 => "write",
    40 => "maintain",
    50 => "admin"
  }

  # Serializes Collaborators from GitLab's Project Team Members
  #
  # #### Model Example:
  #
  # ```
  # {"name"=>"Matt",
  #   "username"=>"spraints",
  #   "id"=>142189,
  #   "state"=>"active",
  #   "avatar_url"=>"https://secure.gravatar.com/avatar/0bf208eebdab7c5d16152f70a1ee837f?s=80&d=identicon",
  #   "web_url"=>"https://gitlab.com/u/spraints",
  #   "access_level"=>40}
  # ```
  class CollaboratorSerializer < BaseSerializer
    # @see GlExporter::BaseSerializer#to_gh_hash
    def to_gh_hash
      # If permission is nil (unmapped), it's not a valid collaborator; return so we can filter it out
      return unless permission

      {
        user: user,
        permission: permission
      }
    end

    private

    def user
      url_for_model(gl_model)
    end

    def permission
      PERMISSION_MAP[gl_model["access_level"]]
    end
  end
end
