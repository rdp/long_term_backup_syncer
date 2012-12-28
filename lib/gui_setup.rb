$: << File.dirname(__FILE__) + "/../vendor/simple_gui_creator/lib"
require 'simple_gui_creator'
include SimpleGuiCreator

@storage = Storage.new('backup_syncher')
def storage
  @storage
end

@a = ParseTemplate.new.parse_setup_filename('lib\\setup.sgc')

def re_configure
  re_configure
  message = "Pick directory that is the root of your shared drive, like your_username/Google Drive or the like:"
  show_message message
  dir = new_existing_dir_chooser_and_go message, File.expand_path('~')
  storage[:root_drive] = dir
  storage[:client_count] = get_input("how many total end storage places will there be?", 2).to_i
  storage[:shared_drive_space_to_use] = get_input("How much shared drive to use for transfers (in GB)", 2.5).to_f
  transfer_dir = File.expand_path('~/backup_synchronizer_drop_files_here')
  File.mkdir(transfer_dir)
  storage[:root_transfer_folder] = new_existing_dir_chooser_and_go("Pick directory where you can drop files in to have them transferred", storage[:root_transfer_folder] || transfer_dir)
  long_term_dir = File.expand_path('~/long_term_local_backup_copy')
  File.mkdir(long_term_dir)
  storage[:longterm_storage_local_dir] = new_existing_dir_chooser_and_go("Folder to use for long term preservation locally", storage[:longterm_storage_local_dir] || long_term_dir)
end

def setup_ui
  a.elements[:root_shared_drive].text = storage[:root_drive]
  a.elements[:client_count].text = storage[:client_count]
  a.elements[:shared_drive_space_to_use].text = storage[:shared_drive_space_to_use]
  a.elements[:root_transfer_folder].text = storage[:root_transfer_folder]
  a.elements[:longterm_storage_local_dir].text = storage[:longterm_storage_local_dir]
end

if !storage[:root_drive]
  re_configure
end

a.elements[:re_configure].on_clicked {
  re_configure
  show_message "ok, restarting app now, hope you weren't in the middle of a transfer..."
  hard_exit!
}

setup_ui # init...

poll_time = 10
synchro_time = 100 # seconds for a trivial file to propagate

class Numeric
  def to_gig
    self * 1e9
  end
end

@subject = IncomingCopier.new a.elements[:root_transfer_folder], storage[:root_drive], storage[:longterm_storage_local_dir], poll_time, synchro_time, 
  storage[:shared_drive_space_to_use].to_gig, total_client_size
  
Thread.new { loop { @subject.go_single_transfer_out } }

loop { @subject.go_single_transfer_in }