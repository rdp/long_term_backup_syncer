$: << File.dirname(__FILE__) + "/../vendor/simple_gui_creator/lib"
require 'simple_gui_creator'
include SimpleGuiCreator

storage = Storage.new('backup_syncher')

if !(dir = storage[:root_drive])
  message = "Pick directory that is the root of your shared drive, like your_username/Google Drive or the like:"
  show_message message
  dir = new_existing_dir_chooser_and_go message, File.expand_path('~')
  storage[:root_drive] = dir
end

a = ParseTemplate.new().parse_setup_filename('lib\\setup.sgc')
a.elements[:root_shared_drive].text = storage[:root_drive]
