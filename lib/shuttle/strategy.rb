require 'uri'

module Shuttle
  class Strategy < Shuttle::Deploy
    def setup
      log "Preparing application structure"

      execute_hook(:before_setup)

      ssh.run "mkdir -p #{deploy_path}"
      ssh.run "mkdir -p #{deploy_path('releases')}"
      ssh.run "mkdir -p #{deploy_path('shared')}"
      ssh.run "mkdir -p #{shared_path('tmp')}"
      ssh.run "mkdir -p #{shared_path('pids')}"
      ssh.run "mkdir -p #{shared_path('log')}"

      execute_hook(:after_setup)
    end

    def deploy
      setup
      update_code
      checkout_code
      link_release
      cleanup_releases
    end

    def rollback
      execute_hook(:before_rollback)

      if last_version == 0
        error "There are no releases to rollback to"
      end

      release = available_releases.select { |v| v == last_version-1 }.first

      if release
        if ssh.run("unlink #{current_path}").failure?
          ssh.run("rm -rf #{current_path}")
        end

        if ssh.run("ln -s #{deploy_path}/releases/#{release} #{current_path}").failure?
          error "Unable to create symlink to current path"
        end

        ssh.run("echo #{release} > #{version_path}")
        ssh.run("rm -rf #{deploy_path}/releases/#{last_version}")

        log "Rolled back to release v#{release}"
      else
        error "There are no older releases"
      end

      execute_hook(:after_rollback)
    end

    def update_code
      if config.app.svn
        return update_code_svn
      end

      error "Git is not installed" if !git_installed?
      error "Git source url is not defined. Please define :git option first" if config.app.git.nil?

      branch = config.app.branch || 'master'

      if ssh.directory_exists?(scm_path)
        # Check if git remote has changed
        current_remote = git_remote
        
        if current_remote != config.app.git
          log("Git remote change detected. Using #{config.app.git}", 'warning')

          res = ssh.run("cd #{scm_path} && git remote rm origin && git remote add origin #{config.app.git}")
          if res.failure?
            error("Failed to change git remote: #{res.output}")
          end
        end

        log "Fetching latest code"
        res = ssh.run "cd #{scm_path} && git pull origin #{branch}"

        if res.failure?
          error "Unable to fetch latest code: #{res.output}"
        end
      else
        log "Cloning repository #{config.app.git}"
        res = ssh.run "cd #{deploy_path} && git clone --depth 25 --recursive --quiet #{config.app.git} scm"

        if res.failure?
          error "Failed to clone repository: #{res.output}"
        end
      end

      ssh.run("cd #{scm_path} && git fetch")

      # Make sure to pull changes from current non-master branch
      if branch != 'master'
        ssh.run("cd #{scm_path} && git pull origin #{branch}")
      end

      log "Using branch '#{branch}'"
      result = ssh.run("cd #{scm_path} && git checkout -m #{branch}")

      if result.failure?
        error "Failed to checkout #{branch}: #{result.output}"
      end

      if ssh.file_exists?("#{scm_path}/.gitmodules")
        log "Updating git submodules"
        result = ssh.run("cd #{scm_path} && git submodule update --init --recursive")

        if result.failure?
          error "Failed to update submodules: #{result.output}"
        end
      end
    end

    def update_code_svn
      error "Subversion is not installed" if !svn_installed?
      error "Subversion source is not defined. Please define :svn option first" if config.app.svn.nil?

      url = URI.parse(config.app.svn)
      repo_url = "#{url.scheme}://#{url.host}#{url.path}"

      opts = ["--non-interactive", "--quiet"]

      if url.user
        opts << "--username #{url.user}"
        opts << "--password #{url.password}" if url.password
      end

      if ssh.directory_exists?(scm_path)
        log "Fetching latest code"

        res = ssh.run("cd #{scm_path} && svn up #{opts.join(' ')}")
        if res.failure?
          error "Unable to fetch latest code: #{res.output}"
        end
      else
        log "Cloning repository #{config.app.svn}"
        res = ssh.run("cd #{deploy_path} && svn checkout #{opts.join(' ')} #{repo_url} scm")

        if res.failure?
          error "Failed to clone repository: #{res.output}"
        end
      end
    end

    def checkout_code(path=nil)
      # Trigger hook before checking out code
      execute_hook(:before_checkout_code)

      checkout_path = [release_path, path].compact.join('/')
      res = ssh.run("cp -a #{scm_path} #{checkout_path}")
      
      if res.failure?
        error "Failed to checkout code. Reason: #{res.output}"
      else
        ssh.run("cd #{release_path} && rm -rf $(find . | grep .git)")
        ssh.run("cd #{release_path} && rm -rf $(find . -name .svn)")
      end

      # Trigger hook after checking out code
      execute_hook(:after_checkout_code)
    end

    def link_release
      if !release_exists?
        error "Release does not exist"
      end

      # Execute before link_release hook
      execute_hook(:before_link_release)

      log "Linking release"

      # Check if `current` is a directory first
      if ssh.run("unlink #{current_path}").failure?
        ssh.run("rm -rf #{current_path}")
      end

      if ssh.run("ln -s #{release_path} #{current_path}").failure?
        error "Unable to create symlink to current path"
      end

      # Write version into RELEASE file
      write_release

      # Write version into current version file
      ssh.run "echo #{version} > #{version_path}"

      log "Release v#{version} has been deployed"

      # Execute after link_release hook, allow failures here
      execute_hook(:after_link_release, true)
    end

    def write_lock
      ssh.run(%{echo #{deployer_hostname} > #{deploy_path}/.lock})
    end

    def release_lock
      ssh.run("rm #{deploy_path}/.lock")
    end

    # Delete current session release
    def cleanup_release
      if ssh.directory_exists?(release_path)
        ssh.run("rm -rf #{release_path}")
      end
    end

    def cleanup_releases
      ssh.run("cd #{deploy_path('releases')}")
      ssh.run("count=`ls -1d [0-9]* | sort -rn | wc -l`")

      count = ssh.capture("echo $count")

      unless count.empty?
        puts count
        num = 0 #Integer(count) - Integer(keep_releases)

        if num > 0
          log "Cleaning up old releases: #{num}" if num > 1

          ssh.run("remove=$((count > #{keep_releases} ? count - #{keep_releases} : 0))")
          ssh.run("ls -1d [0-9]* | sort -rn | tail -n $remove | xargs rm -rf {}")
        end
      end
    end

    def write_revision
      if ssh.directory_exists?(deploy_path('scm'))
        command = nil

        if config.app.git
          command = "git log --format='%H' -n 1"
        elsif config.app.svn
          command = "svn info |grep Revision: |cut -c11-"
        end

        if command
          ssh.run("cd #{scm_path} && #{command} > #{release_path}/REVISION")
        end
      end
    end

    def write_release
      ssh.run("echo #{version} > #{release_path}/RELEASE")
    end

    def disable_history
      ssh.run("set +o history")
    end

    def export_environment
      ssh.export_hash(
        'DEPLOY_APP'          => config.app.name,
        'DEPLOY_APPLICATION'  => config.app.name,
        'DEPLOY_USER'         => target.user,
        'DEPLOY_PATH'         => deploy_path,
        'DEPLOY_RELEASE'      => version,
        'DEPLOY_RELEASE_PATH' => release_path,
        'DEPLOY_CURRENT_PATH' => current_path,
        'DEPLOY_SHARED_PATH'  => shared_path,
        'DEPLOY_SCM_PATH'     => scm_path
      )

      if config.env?
        log "Exporting environment variables"

        config.env.each_pair do |k, v|
          ssh.export(k, v)
        end
      end
    end

    def execute_hook(name, allow_failures=false)
      if config.hooks && config.hooks[name]
        execute_commands(config.hooks[name], allow_failures)
      end
    end

    def deploy_running?
      ssh.file_exists?("#{deploy_path}/.lock")
    end

    def connect
      exec("ssh #{target.user}@#{target.host}")
    end

    def keep_releases
      config.app.keep_releases || 10
    end

    def changes_at?(path)
      result = ssh.run(%{diff -r #{current_path}/#{path} #{release_path}/#{path} 2>/dev/null})
      result.success? ? false : true
    end

    def execute_commands(commands=[], allow_failures=false)
      Shuttle::Hook.new(self).run(commands, allow_failures)
    end
  end
end