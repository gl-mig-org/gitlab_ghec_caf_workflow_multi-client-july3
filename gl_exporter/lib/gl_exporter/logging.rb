# frozen_string_literal: true
class GlExporter
  module Logging
    def self.included(base)
      base.extend(ClassMethods)
    end

    def logger
      @logger ||= Logger.new(File.join(logs_dir, "gl-exporter.log"))
    end

    def output_logger
      self.class.output_logger
    end

    module ClassMethods
      def output_logger
        @output_logger ||= Logger.new(STDOUT).tap do |logger|
          logger.progname = "gl-exporter"
        end
      end
    end

    private

    def logs_dir
      "./log/"
    end
  end
end
