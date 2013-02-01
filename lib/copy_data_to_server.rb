require 'fileutils'
require 'simple_gui_creator' # we use it inline now

class IncomingCopier

  def initialize local_drop_here_to_save_dir, dropbox_root_local_dir, longterm_storage_dir, sleep_time, synchro_time, 
        dropbox_size, total_client_size
    @local_drop_here_to_save_dir = File.expand_path local_drop_here_to_save_dir
    @sleep_time = sleep_time
    @dropbox_root_local_dir = File.expand_path dropbox_root_local_dir
    @synchro_time = synchro_time
    @dropbox_size = dropbox_size
    @total_client_size = total_client_size
    @longterm_storage_dir = longterm_storage_dir
    FileUtils.mkdir_p lock_dir
    FileUtils.mkdir_p dropbox_temp_transfer_dir
    FileUtils.mkdir_p track_when_client_done_dir
    @transfer_count = 0
    @prompt_before_uploading = nil
  end
  
  # most of these for unit tests...
  attr_accessor :sleep_time
  attr_reader :longterm_storage_dir
  attr_accessor :prompt_before_uploading
  attr_reader :local_drop_here_to_save_dir
  attr_accessor :quiet_mode
  attr_accessor :total_client_size

  def dropbox_temp_transfer_dir
    "#{@dropbox_root_local_dir}/backup_syncer/temp_transfer_big_dir"
  end
  
  def lock_dir
    "#{@dropbox_root_local_dir}/backup_syncer/synchronization"
  end
  
  def track_when_client_done_dir
    "#{@dropbox_root_local_dir}/backup_syncer/track_which_clients_are_done_dir"
  end
  
  def sleep!(output_char, sleep_time=@sleep_time)
    sleep sleep_time
    print output_char, ' ' unless quiet_mode
  end
  
  def files_incoming(use_temp_renamed_local_dir = false)
    if use_temp_renamed_local_dir
      dir = renamed_being_transferred_dir
    else
      dir = @local_drop_here_to_save_dir
    end
    Dir[dir + '/**/*']
  end

  def wait_for_any_files_to_appear
    while files_incoming.length == 0
      sleep!('wait_for_any_files_to_appear')
        if @shutdown
        raise 'shutting down'
      end
    end
  end
  
  def show_in_explorer filename
    SimpleGuiCreator.show_in_explorer filename
  end
  
  def show_select_buttons_prompt *args # :yes => ...
    SimpleGuiCreator.show_select_buttons_prompt *args
  end
  
  def cleanup_old_broken_runs
    if File.directory?(renamed_being_transferred_dir)
      if Dir[renamed_being_transferred_dir + '/*'].length > 0 && Dir[local_drop_here_to_save_dir + '/*'].length == 0
        if show_select_buttons_prompt("appears there was an interrupted transfer, would you like to restart it?") == :yes
          FileUtils.rmdir local_drop_here_to_save_dir          
          FileUtils.mv renamed_being_transferred_dir, local_drop_here_to_save_dir
          return
        end
      end
      # TODO prompt delete here too?
      SimpleGuiCreator.show_message("warning, dirty temp dir #{renamed_being_transferred_dir} please cleanup first?")
      show_in_explorer renamed_being_transferred_dir
    end 
  end  
  
  attr_reader :local_drop_here_to_save_dir
  
  def wait_for_incoming_files_and_rename_entire_dir  
    if @prompt_before_uploading
      @prompt_before_uploading.call
    end    
    assert !File.directory?(renamed_being_transferred_dir) # should have been cleaned up already [!]...
    FileUtils.mv local_drop_here_to_save_dir, renamed_being_transferred_dir
    Dir.mkdir local_drop_here_to_save_dir # recreate it
  end
  
  def old_lock_files_this_box
    Dir["#{lock_dir}/request_#{Socket.gethostname}_*.lock"].reject{|f| f == this_process_lock_file} # just want old ones :)
  end
  
  def this_process_lock_file
    "#{lock_dir}/request_#{Socket.gethostname}_#{Process.pid}.lock"
  end
  
  def previous_you_can_go_for_it_size_file
    @previous_go_for_it_filename || 'fake for unit tests'
  end
  
  def next_you_can_go_for_it_after_size_file current_chunk_size
    # use filename instead of size, to make it synchronously created with its contents :)
    @previous_go_for_it_filename = "#{lock_dir}/begin_transfer_courtesy_#{Socket.gethostname}_#{Process.pid}_#{@transfer_count += 1}_#{current_chunk_size}"
  end
  
  def sanity_check_clean_and_locked
    assert have_lock?, "should be locked"
	# we have the lock, so we can control these, right?
	# TODO re-lock? give it some more time?
    if client_done_copying_files.length != 0
	  if show_select_buttons_prompt("detected some orphaned 'transfer done' files, delete them?") == :yes
	    client_done_copying_files.each{|f| File.delete(f) }
      else
	    raise 'dunno what to do here'
	  end
	end
    if current_transfer_ready_files.length != 0
	  if show_select_buttons_prompt("detected some orphaned 'transfer read' files, delete them?") == :yes
	    current_transfer_ready_files.each{|f| File.delete(f) }
	  else
	    raise 'dunno how to proceed'	  
	  end	
	end
  end
  
  # LODO assert that the 'go' file for clients is still there when they finish...though what could they ever do in that case? prompt at least?
  
  def touch_the_you_can_go_for_it_file current_chunk_size
    sanity_check_clean_and_locked
    FileUtils.touch next_you_can_go_for_it_after_size_file(current_chunk_size)
  end
  
  def all_lock_files
    Dir[lock_dir + '/*.lock']  
  end
  
  def wait_if_already_has_lock_files
    if old_lock_files_this_box.length > 0
      if show_select_buttons_prompt("found some apparent old lock files from this box, they'r eprobably orphaned, delete them?\n#{old_lock_files_this_box.join(', ')}") == :yes
        old_lock_files_this_box.each{|f| File.delete(f) }
      end
    end
    while all_lock_files.length > 0
      raise 'double locking confusion?' if File.exist? this_process_lock_file
      sleep!('waiting for old lock files to disappear ' + all_lock_files.join(' '))
    end
  end
  
  def create_lock_file
    FileUtils.touch this_process_lock_file    
  end
  
  def have_lock?
    all_lock_files == [this_process_lock_file] # can't be more than us :)
  end
  
  # returns true if "we got the lock", or false if there is contention for it
  def wait_for_lock_files_to_stabilize
    start_time = Time.now
    while ((elapsed_time = Time.now - start_time) < @synchro_time) && !File.exist?('pretend_lock_files_have_already_stabilized') # speed up IT testing
      if !have_lock?
        delete_lock_file # 2 people requested the lock, so both give up (or possibly just this 1 give up)
        return false
      else
        sleep!("wait_for_lock_files_to_stabilize #{elapsed_time} < #{@synchro_time}")
      end
    end
    true
  end
  
  def obtain_lock
    got_it = false
    while !got_it
      wait_if_already_has_lock_files
      create_lock_file
      got_it = wait_for_lock_files_to_stabilize
    end
  end
  
  def split_up_file filename
    size = 0
	file_size = File.size filename
	pieces = file_size / @dropbox_size
	file_count = 0
	File.open(filename, 'rb') do |from_file|
	  while size < file_size
	    File.open("#{filename}___piece_#{file_count}_of_#{pieces}", 'wb') do |to_file|
	      to_file.syswrite(from_file.sysread(@dropbox_size))
		  size += @dropbox_size
		  file_count += 1
	    end
	  end
	end
    FileUtils.rm filename  
  end
  
  def split_to_chunks
    out = []
    current_group = []
    current_sum = 0    
    files_to_chunk = files_incoming(true).sort
    raise 'no files huh?' if files_to_chunk.empty?
    files_to_chunk.each{|f|
      if File.file? f
        file_size = File.size f
      else
        file_size = 0 # count directories as 0 size
      end
	  if file_size > @dropbox_size
	    
	  end
	  
      if file_size + current_sum > @dropbox_size
        out << [current_group, current_sum]
        current_group = [f] # f might be bigger than @dropbox_size...
        current_sum = file_size # reset current_sum
      else
        current_group << f
        current_sum += file_size
      end
    }
    out << [current_group, current_sum] unless current_group.empty? # last group
    out
  end
  
  raise unless JRUBY_VERSION >= '1.7.2' # avoid JRUBY-7046 here or there...
  
  def renamed_being_transferred_dir
    @local_drop_here_to_save_dir + '.being_transferred'
  end
  
  def copy_files_over files, relative_to_strip_from_files, to_this_dir, name
    sum_transferred = 0
    for filename in files
      relative_extra_dir = filename[(relative_to_strip_from_files.length + 1)..-1] # like "subdir/b"
      new_subdir = to_this_dir + '/' + File.dirname(relative_extra_dir)
      FileUtils.mkdir_p new_subdir # I guess we might be able to use some type of *args to FileUtils.cp_r here?
      if(File.file? filename)
        FileUtils.cp filename, new_subdir
        sleep!('copy_files_over' + name, 0) # status update :)        
        sum_transferred += File.size(new_subdir + '/' + File.filename(filename)) # getting a file size after copy should be safe, shouldn't it?
      else
        assert File.directory?(filename)
        FileUtils.mkdir_p new_subdir + '/' + relative_extra_dir
      end
    end
    sum_transferred
  end
  
  def copy_chunk_to_dropbox chunk, size
    if Dir[dropbox_temp_transfer_dir + '/*'].length != 0
      show_in_explorer dropbox_temp_transfer_dir
      show_message "transfer directory is dirty from a previous run, please clean it up, and del it\nor hit ok and leave stuff in it to abort current transfer (or touch trust_dropbox file)"
      assert Dir[dropbox_temp_transfer_dir + '/*'].length == 0, "shared temp transfer drop dir had some unknown files in it?"
    end
    copy_files_over chunk, renamed_being_transferred_dir, dropbox_temp_transfer_dir, 'to dropbox'
    assert file_size_incoming_from_dropbox == size, "expecting size #{size} but put size #{file_size_incoming_from_dropbox}"
  end
  
  def copy_files_in_by_chunks
    sanity_check_clean_and_locked
    for chunk, size in split_to_chunks
      copy_chunk_to_dropbox chunk, size
      touch_the_you_can_go_for_it_file size
      wait_for_all_clients_to_copy_files_out
      File.delete previous_you_can_go_for_it_size_file
      FileUtils.rm_rf dropbox_temp_transfer_dir
	  mkdir_ignore_errors dropbox_temp_transfer_dir  # google drive can die here
    end
  end
  
  def mkdir_ignore_errors dir
    begin
      Dir.mkdir dir
	rescue Errno::EIO => busy
	  sleep 10
	  retry
	end
  end
  
  def delete_lock_file
    File.delete this_process_lock_file
  end
  
  def client_done_copying_files
    Dir[track_when_client_done_dir + '/*']
  end
  
  def wait_for_all_clients_to_copy_files_out
    while (got = client_done_copying_files.length) != @total_client_size
      sleep! "wait_for_all_clients_to_copy_files_out #{got} < #{@total_client_size}"
    end
	sleep! "detected all clients are done, deleting their notification files", 0
    for file in client_done_copying_files
      File.delete file
    end
  end

  # the only one you should call...
  def go_single_transfer_out
    wait_for_any_files_to_appear
    wait_for_incoming_files_and_rename_entire_dir
    obtain_lock
    begin
      copy_files_in_by_chunks
	  # delete the local temp dir
      FileUtils.rm_rf renamed_being_transferred_dir # should be all copies over... :)
    ensure
      delete_lock_file
    end    
  end
  
  require 'copy_from_server'
 
end