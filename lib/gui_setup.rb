require File.dirname(__FILE__) + "/copy_data_to_server.rb"
$: << File.dirname(__FILE__) + "/../vendor/simple_gui_creator/lib"
require 'simple_gui_creator'
require 'fileutils'

include SimpleGuiCreator
extend SimpleGuiCreator

@storage = Storage.new('backup_syncher')

def storage
  @storage
end

@a = ParseTemplate.new.parse_setup_filename('lib\\setup.sgc')

def a
  @a
end

def show_message message
  SimpleGuiCreator.show_message message
end

def new_existing_dir_chooser_and_go *args
  SimpleGuiCreator.new_existing_dir_chooser_and_go *args
end

def get_input title, value
  SimpleGuiCreator.get_input title, value
end

def re_configure
  message = "Pick directory that is the root of your shared drive, like your_username/Google Drive or the like:"  
  show_message message unless storage[:root_drive]
  dir = new_existing_dir_chooser_and_go message, storage[:root_drive] || File.expand_path('~')
  storage[:root_drive] = dir
  storage[:client_count] = get_input("how many total end storage places will there be?", 2).to_i
  storage[:shared_drive_space_to_use] = get_input("How much shared drive to use for transfers (in GB)", storage[:shared_drive_space_to_use] || 2.5).to_f
  transfer_dir = File.expand_path('~/synchronizer_drop_files_here_they_will_be_copied_out_then_deleted')
  FileUtils.mkdir_p(transfer_dir)
  storage[:drop_into_folder] = new_existing_dir_chooser_and_go("Pick directory where you can drop files in to have them transferred", storage[:drop_into_folder] || transfer_dir)
  long_term_dir = File.expand_path('~/long_term_local_backup_copy')
  FileUtils.mkdir_p(long_term_dir)
  storage[:longterm_storage_local_dir] = new_existing_dir_chooser_and_go("Folder to use for long term preservation locally", storage[:longterm_storage_local_dir] || long_term_dir)
end

def setup_ui
  a.elements[:root_shared_drive].text = storage[:root_drive]
  a.elements[:client_count].text = storage[:client_count].to_s
  a.elements[:shared_drive_space_to_use].text = storage[:shared_drive_space_to_use].to_s
  a.elements[:drop_into_folder].text = storage[:drop_into_folder]
  a.elements[:longterm_storage_local_dir].text = storage[:longterm_storage_local_dir]
end

if !storage[:longterm_storage_local_dir]
  re_configure
end

a.elements[:re_configure].on_clicked {
  re_configure
  show_message "ok, shutting down app now, then restart it..."
  shutdown
}

a.elements[:open_drop_into_folder].on_clicked {
  SimpleGuiCreator.show_in_explorer(storage[:drop_into_folder]+ '/.')
}

a.elements[:open_gdrive_folder].on_clicked {
  SimpleGuiCreator.show_in_explorer(storage[:root_drive] + '/.')
}

a.elements[:shutdown].on_clicked {
  shutdown
}

a.after_closed {
  shutdown # just in case
  # LODO warn if they hit the 'X'?
}

def shutdown
  a.elements[:status].text = "shutting down..."
  unless @subject.shutdown
    @subject.shutdown! 
    Thread.new {
      @t1.join  
      @t2.join
      a.close!
    }
  end 
end

setup_ui # init...

class Numeric
  def to_gig
    self * 1e9
  end
end

poll_time = 3
synchro_time = 30 # seconds for a trivial file to propagate TODO 100 ?

@subject = IncomingCopier.new storage[:drop_into_folder], storage[:root_drive], storage[:longterm_storage_local_dir], poll_time, synchro_time, 
  storage[:shared_drive_space_to_use].to_gig, storage[:client_count]

@subject.cleanup_old_broken_runs # TODO other thread?/non blocking mode?

# LODO just handle the waiting all here? yeah prolly
@subject.prompt_before_uploading = proc {
  got = :no
  while got == :no
    got = SimpleGuiCreator.show_select_buttons_prompt("we have detected some files are ready to upload #{Dir[@subject.local_drop_here_to_save_dir + '/*'].map{|f| File.filename(f)}.join(', ')},\n would you like to do that now, or wait\n(to put more files there or rename some first)?", :yes => "Now, I'm ready!", :no => "wait")
	if got == :no
      sleep 10
	end
  end  
}
  
@t1 = Thread.new { loop { @subject.go_single_transfer_out } }

@t2 = Thread.new { loop { @subject.go_single_transfer_in } }

t3 = Thread.new { 
  loop {
    if !@t1.alive? || !@t2.alive?
      if !@subject.shutdown
	    show_message("thread died early?")
	    shutdown
	    break
	  end
    end
    sleep 1
  }
}
