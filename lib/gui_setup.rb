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
  message = "Pick directory that is the root of your shared cloud drive, like username\\dropbox or something:"  
  show_message message unless storage[:root_drive]
  dir = new_existing_dir_chooser_and_go message, storage[:root_drive] || File.expand_path('~')
  if dir =~ /google drive/i
    show_message "warning, using google drive is not recommended since it can only copy 5GB before you have to \nmanually empty the trash online for it, suggest use something else..."
  end
  storage[:root_drive] = dir
  storage[:client_count] = get_input("how many total end storage repo's will there be, including this one?", (storage[:client_count] || 2)).to_i
  storage[:shared_drive_space_to_use] = get_input("How much shared drive space to use for outgoing transfers (in GB, typically the size of your cloud storage less a bit)", storage[:shared_drive_space_to_use] || 2.0).to_f
  # LODO this feels a bit messed up, always mkdir'ing everything...
  transfer_dir = File.expand_path('~/synchronizer_drop_files_here_they_will_be_copied_out_then_deleted')
  FileUtils.mkdir_p(transfer_dir)
  storage[:drop_into_folder] = new_existing_dir_chooser_and_go("Pick directory where you can drop files in to have them transferred", storage[:drop_into_folder] || transfer_dir)
  long_term_dir = File.expand_path('~/long_term_local_repository_backup_copy')
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
  show_message "ok, shutting down app now, restart it for new changes to take effect..."
  shutdown
}

def reveal_drop_into_folder
  SimpleGuiCreator.show_in_explorer(storage[:drop_into_folder] + '/.')
end

a.elements[:open_drop_into_folder].on_clicked {
  reveal_drop_into_folder
}

a.elements[:open_long_term_folder].on_clicked {
 SimpleGuiCreator.show_in_explorer(storage[:longterm_storage_local_dir] + '/.')
}

a.elements[:shutdown].on_clicked {
  shutdown
}

a.after_closed {
  shutdown # just in case
  # LODO warn if they hit the 'X'?
}

def shutdown
  puts 'shutting down...'
  a.elements[:status].text = "shutting down..."
  unless @subject.shutdown
    @subject.shutdown!
    Thread.new {
    p 'join1'
      @t1.join
      p 'join2'
      @t2.join
      p 'closing...'
      a.close!
    }
  end
 
end

setup_ui # init...

class Numeric # could start as Float...
  def as_GB
    # but we still want an int out...
    (self * 1e9).to_i
  end
end

poll_time = 3
synchro_time = 130 # seconds for a trivial lock file to propagate to all clients [TODO test]

@subject = IncomingCopier.new storage[:drop_into_folder], storage[:root_drive], storage[:longterm_storage_local_dir], poll_time, synchro_time, 
  storage[:shared_drive_space_to_use].as_GB, storage[:client_count]

@subject.cleanup_old_broken_runs

@subject.prompt_before_uploading = proc {
  got = :no
  while got == :no
    begin
	  got = SimpleGuiCreator.show_select_buttons_prompt("we have detected some files are ready to upload #{Dir[@subject.local_drop_here_to_save_dir + '/*'].map{|f| File.filename(f)[0..20]}.join(', ')},\n would you like to do that now, or wait\n(to put more files there or rename them first)?", :yes => "Now, the files are all ready!", :no => "reveal files", :cancel => "wait 15s")
	rescue => e
	  # X, don't just re-appear...
	  sleep 15
	end
	if got == :no
	  reveal_drop_into_folder      
	elsif got == :cancel
	  sleep 15
	end
  end
}

@subject.send_updates_here = proc { |type, status|
  if type == :server
    a.elements[:current_upload_status].text = status
  elsif type == :client
    a.elements[:current_download_status].text = status
  else
   raise
  end
}
  
@t1 = Thread.new { 
  begin
  loop { 
    @subject.go_single_transfer_out 
  } 
  rescue => e
    show_message "thread died #{e} #{e.backtrace.join("\n")}" unless e.to_s =~ /shutting down/
  end
}

@t2 = Thread.new { 
  begin
  loop { 
    @subject.go_single_transfer_in 
  } 
  rescue => e
    show_message "thread2 died #{e}  #{e.backtrace.join("\n")}" unless e.to_s =~ /shutting down/ # LODO more graceful, just exit??
  end
}

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
