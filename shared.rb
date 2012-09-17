# client, basically

require 'yaml'
local_config_hash = YAML.load 'local_config.yml'
@local_drop_here_to_save_dir = local_config_hash[:local_drop_here_to_save_dir]
