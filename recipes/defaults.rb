load "set_servers"

set :branch,        ENV["TAG"] ? ENV["TAG"] : "master"
set :deploy_to,     "/data/apps/#{application}"
set :deploy_via,    :rsync_with_remote_cache
set :organisation,  ENV['ORGANISATION']
set :keep_releases, 5
set :rake,          "govuk_setenv #{application} #{fetch(:rake, 'bundle exec rake')}"
set :repo_name,     fetch(:repo_name, application).to_s # XXX: this must appear before the `require 'defaults' in recipe names
set :repository,    "#{ENV.fetch('GIT_ORIGIN_PREFIX', 'git@github.com:alphagov')}/#{repo_name}.git"
set :scm,           :git
set :ssh_options,   { :forward_agent => true, :keys => "#{ENV['HOME']}/.ssh/id_rsa" }
set :use_sudo,      false
set :user,          "deploy"

# Always run deploy:setup on every server as it's idempotent
after "deploy:set_servers", "deploy:setup"

namespace :deploy do
  task :default do
    transaction do
      update_code
    end
    if fetch(:run_migrations_by_default, false)
      set :migrate_target, :latest
      migrate
    end
    symlink
    restart
  end

  desc "Deploy with migrations, similar to default but migrations are not app dependent"
  task :with_migrations do
    set :run_migrations_by_default, true
    default
  end

  desc "Deploy without running migrations.  Use with caution."
  task :without_migrations do
    update
    restart
  end

  task :upload_config, :roles => [:app, :web] do
    # mkdir -p is making sure that the directories are there for some SCM's that don't
    # save empty folders
    unless fetch(:config_files_to_upload, nil).nil?
      config_files_to_upload.each do |from_path, to_path|
        unless File.exist? from_path
          raise "Does not exist: #{from_path}"
        end
        if from_path.end_with? ".erb"
          erb_file = ERB.new(File.read(from_path)).result(binding)
          put(erb_file, File.join(release_path, to_path))
        else
          top.upload(from_path, File.join(release_path, to_path))
        end
      end
    end

    if fetch(:source_db_config_file, false) && fetch(:db_config_file, false) && File.file?(source_db_config_file)
      database_yaml = ERB.new(File.read(source_db_config_file)).result(binding)
      put(database_yaml, File.join(release_path, db_config_file))
    end
  end
end

after "deploy:finalize_update", "deploy:upload_config"
after "deploy:restart", "deploy:cleanup"

namespace :deploy do
  desc "Notifies external services of a successful deployment"
  namespace :notify do
    task :default do
      release_app
      graphite_event
    end

    desc "Register the deployment with the 'release' app"
    task :release_app do
      release_app_url = 'https://release.publishing.service.gov.uk'
      manual_resolution_message = "ACTION REQUIRED: Failed to notify Release app of deploy. Please add this deploy manually at #{release_app_url}"

      require "net/http"
      bearer_token = ENV["RELEASE_APP_NOTIFICATION_BEARER_TOKEN"]
      if bearer_token.nil?
        puts "RELEASE_APP_NOTIFICATION_BEARER_TOKEN not set, can't notify Release app of deploy."
        raise manual_resolution_message
      else
        begin
          url = URI.parse("#{release_app_url}/deployments")
          request = Net::HTTP::Post.new(url.path)
          conn = Net::HTTP.new(url.host, url.port)
          conn.use_ssl = true

          form_data = {
            "repo"                    => repository,
            "deployment[version]"     => ENV['TAG'],
            "deployment[environment]" => organisation
          }
          request.set_form_data(form_data)
          request["Accept"] = "application/json" # So that gds-sso will treat us as an API client
          request["Authorization"] = "Bearer #{bearer_token}"
          response = conn.request(request)
          puts "Deployment notification response:"
          puts "#{response.code} #{response.body}"
        rescue => e
          puts "Release notification failed: #{e.message}"
          raise manual_resolution_message
        end
      end
    end

    desc "Record the deployment as a Graphite event"
    task :graphite_event do
      require 'json'
      require 'net/http'
      require 'uri'

      begin
        req = Net::HTTP::Post.new('/events/')
        req["Content-Type"] = 'application/json'
        req.body = { what: 'deploy',
                     tags: "#{application} #{ENV['ORGANISATION']} deploys",
                     data: "#{branch} #{current_revision[0, 7]} #{user}" }.to_json
        req.basic_auth(ENV['GRAPHITE_USER'], ENV['GRAPHITE_PASSWORD'])
        Net::HTTP.new('graphite.cluster', '80').start { |http| http.request(req) }
      rescue => e
        puts "Graphite notification failed: #{e.message}"
      end
    end

    task :errbit, :only => { :primary => true } do
      run "cd #{current_release} && #{rake} airbrake:deploy REVISION=#{current_revision} TO=#{organisation} REPO='#{repository}' USER=#{user}", :once => true
    end

    task :github, :only => { :primary => true } do
      run_locally "cd #{strategy.local_cache_path}; git push -f #{repository} HEAD:refs/heads/deployed-to-#{ENV['ORGANISATION']}"
    end
  end

  namespace :panopticon do
    task :register, :only => { :primary => true, :draft => false } do
      rails_env = fetch(:rails_env, "production")
      rake = fetch(:rake)
      run "cd #{current_release}; #{rake} RAILS_ENV=#{rails_env} panopticon:register", :once => true
    end
  end

  namespace :publishing_api do
    task :publish, :only => { :primary => true, :draft => false } do
      rails_env = fetch(:rails_env, "production")
      rake = fetch(:rake)
      run "cd #{current_release}; #{rake} RAILS_ENV=#{rails_env} publishing_api:publish", :once => true
    end

    task :publish_special_routes, :only => { :primary => true, :draft => false } do
      rails_env = fetch(:rails_env, "production")
      rake = fetch(:rake)
      run "cd #{current_release}; #{rake} RAILS_ENV=#{rails_env} publishing_api:publish_special_routes", :once => true
    end
  end

  namespace :email do
    task :register_subscriptions, :only => { :primary => true } do
      rails_env = fetch(:rails_env, "production")
      rake = fetch(:rake)
      run "cd #{current_release}; #{rake} RAILS_ENV=#{rails_env} email_subscriptions:register_subscriptions", :once => true
    end
  end

  namespace :rummager do
    task :index, :only => { :primary => true } do
      rails_env = fetch(:rails_env, "production")
      rake = fetch(:rake)
      run "cd #{current_release}; #{rake} RAILS_ENV=#{rails_env} rummager:index", :once => true
    end
  end
end

namespace :deploy do
  desc "Restart the procfile worker"
  task :restart_procfile_worker do
    procfile_worker_name = "#{application}-procfile-worker"
    run "sudo initctl start #{procfile_worker_name} || sudo initctl restart #{procfile_worker_name}"
  end
end

after "deploy", "deploy:notify"
after "deploy:cold", "deploy:notify"
after "deploy:migrations", "deploy:notify"
