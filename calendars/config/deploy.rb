set :application, "calendars"
set :capfile_dir, File.expand_path('../', File.dirname(__FILE__))
set :server_class, "calculators_frontend"

load 'defaults'
load 'ruby'
load 'deploy/assets'

set :assets_prefix, 'calendars'
set :rails_env, 'production'
set :source_db_config_file, false
set :db_config_file, false

namespace :deploy do
  task :cold do
    puts "There's no cold task for this project, just deploy normally"
  end
end

after "deploy:upload_initializers", "deploy:symlink_mailer_config"
after "deploy:symlink", "deploy:panopticon:register"
after "deploy:symlink", "deploy:rummager:index_all"
after "deploy:symlink", "deploy:publishing_api:publish"
after "deploy:notify", "deploy:notify:errbit"
