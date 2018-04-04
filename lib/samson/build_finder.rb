# frozen_string_literal: true
# makes sure all builds that are needed for a deploy are successfully built
# (needed builds are determined by projects `dockerfiles` column or passed in image list)
#
# Special cases:
# - when no Dockerfile is in the repo and it is the only requested dockerfile (column default value), return no builds
# - if a build is not found, but the project has as `docker_release_branch` we wait a few seconds and retry
# - builds can be reused from the previous release if the deployer requested it
# - if the deploy is cancelled we finish up asap
# - we find builds across all projects so multiple projects can share them
module Samson
  class BuildFinder
    TICK = 2.seconds

    def initialize(output, job, reference, build_selectors: nil)
      @output = output
      @job = job
      @reference = reference
      @cancelled = false
      @build_selectors = build_selectors
    end

    # deploy was cancelled, so finish up as fast as possible
    def cancelled!
      @cancelled = true
    end

    def ensure_successful_builds
      builds = find_or_create_builds
      builds.compact.each do |build|
        payload = { project: build.project.name, gcb: build.external? }
        ActiveSupport::Notifications.instrument("wait_for_build.samson", payload) do
          wait_for_build_completion(build)
        end
        ensure_build_is_successful(build) unless @cancelled
      end
    end

    def find_or_create_builds
      needed =
        if @build_selectors
          @build_selectors.dup
        else
          @job.project.dockerfile_list.map { |d| [d, @job.project.docker_image(d)] }
        end

      build_disabled = @job.project.docker_image_building_disabled?
      all = []

      wait_for_build_creation do |last_try|
        possible = possible_builds
        needed.delete_if do |dockerfile, image|
          found = self.class.detect_build_by_selector!(
            possible, dockerfile, image, fail: (last_try && build_disabled)
          )
          if found
            all << found
          elsif last_try
            raise unless dockerfile # should never get here
            raise if build_disabled # should never get here
            all << create_build(dockerfile)
          end
        end
        needed.empty? # stop the waiting when we got everything
      end

      all
    end

    def self.detect_build_by_selector!(builds, dockerfile, image, fail:)
      image_name = image.split('/').last.split(/[:@]/, 2).first if image
      found = builds.detect do |b|
        (image_name && b.image_name == image_name) || (dockerfile && b.dockerfile == dockerfile)
      end
      return found if found || !fail

      raise(
        Samson::Hooks::UserError,
        "Did not find build for dockerfile #{dockerfile.inspect} or image_name #{image_name.inspect}.\n" \
        "Found builds: #{builds.map { |b| [b.dockerfile, b.image_name] }.uniq.inspect}."
      )
    end

    private

    # all the builds we could use, starting with the finished ones
    def possible_builds
      commits = [@job.commit]

      if defined?(SamsonKubernetes) && @job.deploy.kubernetes_reuse_build
        previous = @job.deploy.previous_deploy&.job&.commit
        commits.unshift previous if previous
      end

      Build.where(git_sha: commits).sort_by { |build| commits.index(build.git_sha) }
    end

    # we only wait once no matter how many builds are missing since build creation is fast
    def wait_for_build_creation
      interval = 5
      @wait_time ||= max_build_wait_time

      loop do
        @wait_time -= interval
        last_try = @wait_time < 0

        build = yield last_try
        return build if build

        break if last_try || @cancelled
        sleep interval
      end
    end

    def max_build_wait_time
      if @job.project.docker_image_building_disabled?
        Integer(ENV['KUBERNETES_EXTERNAL_BUILD_WAIT'] || ENV['EXTERNAL_BUILD_WAIT'] || '5')
      elsif @job.project.docker_release_branch.present?
        5 # wait a little to avoid duplicate builds on release branch callback
      else
        0
      end
    end

    def create_build(dockerfile)
      name = "build for #{dockerfile}"

      if @job.project.repository.file_content(dockerfile, @job.commit)
        @output.puts("Creating #{name}.")
        build = Build.create!(
          git_sha: @job.commit,
          git_ref: @reference,
          creator: @job.user,
          project: @job.project,
          dockerfile: dockerfile,
          name: "Autobuild for Deploy ##{@job.deploy.id}"
        )
        DockerBuilderService.new(Build.find(build.id)).run # .find to not update/reload the same object
        build
      else
        raise(
          Samson::Hooks::UserError,
          "Could not create #{name}, since #{dockerfile} does not exist in the repository."
        )
      end
    end

    def wait_for_build_completion(build)
      if build.reload.active?
        @output.puts("Waiting for Build #{build.url} to finish.")
      else
        @output.puts("Build #{build.url} is finished.")
        return
      end

      loop do
        break if @cancelled
        sleep TICK
        break unless build.reload.active?
      end
    end

    def ensure_build_is_successful(build)
      if build.docker_repo_digest
        unless Samson::Hooks.fire(:ensure_build_is_successful, build, @job, @output).all?
          raise Samson::Hooks::UserError, "Plugin build checks for #{build.url} failed."
        end
        @output.puts "Build #{build.url} is looking good!"
      elsif build_job = build.docker_build_job
        raise Samson::Hooks::UserError, "Build #{build.url} is #{build_job.status}, rerun it."
      else
        raise Samson::Hooks::UserError, "Build #{build.url} was created but never ran, run it."
      end
    end
  end
end
