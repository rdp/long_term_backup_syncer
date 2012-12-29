require 'fileutils'

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
  
  attr_accessor :sleep_time
  attr_reader :longterm_storage_dir
  attr_accessor :prompt_before_uploading
  attr_reader :local_drop_here_to_save_dir

  def dropbox_temp_transfer_dir
    "#{@dropbox_root_local_dir}/temp_transfer"
  end
  
  def lock_dir
    "#{@dropbox_root_local_dir}/synchronization"
  end
  
  def track_when_client_done_dir
    "#{@dropbox_root_local_dir}/track_who_is_done_dir"
  end
  
  def sleep!(output_char, sleep_time=@sleep_time)
    sleep sleep_time
    print output_char, ' '
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
  
  def cleanup_old_broken_runs
    if File.directory?(renamed_being_transferred_dir)
	  SimpleGuiCreator.show_message("warning, dirt dir #{renamed_being_transferred_dir} please cleanup first") # TODO prompt here
	  show_in_explorer renamed_being_transferred_dir
	end
  end  
  
  def wait_for_incoming_files_and_rename_entire_dir  
	if @prompt_before_uploading
	  @prompt_before_uploading.call
	end	
    assert !File.directory?(renamed_being_transferred_dir) # should have been cleaned up already [!]...
    FileUtils.mv @local_drop_here_to_save_dir, renamed_being_transferred_dir
    Dir.mkdir @local_drop_here_to_save_dir # recreate it
  end
  
  def this_process_lock_file
    "#{@dropbox_root_local_dir}/synchronization/request_#{Socket.gethostname}_#{Process.pid}.lock"
  end
  
  def previous_you_can_go_for_it_size_file
    @previous_go_for_it_filename || 'fake for unit tests'
  end
  
  def next_you_can_go_for_it_after_size_file(current_chunk_size)
    # use filename instead of size, to make it synchronously created with its contents :)
    @previous_go_for_it_filename = "#{@dropbox_root_local_dir}/synchronization/begin_transfer_courtesy_#{Socket.gethostname}_#{Process.pid}_#{@transfer_count += 1}_#{current_chunk_size}"
  end
  
  def touch_the_you_can_go_for_it_file current_chunk_size
    assert have_lock?, "should be locked"
    assert client_done_copying_files.length == 0 # just in case :P
    assert current_transfer_ready_files.length == 0 # just in case :P
    FileUtils.touch next_you_can_go_for_it_after_size_file(current_chunk_size)
  end
  
  def wait_if_already_has_lock_files
    raise 'double locking confusion?' if File.exist? this_process_lock_file
    while Dir[lock_dir + '/*'].length > 0
      sleep!('wait_if_already_has_lock_files' + Dir[lock_dir + '/*'].join(' '))
    end
  end
  
  def create_lock_file
    FileUtils.touch this_process_lock_file    
  end
  
  def have_lock?
    Dir[lock_dir + '/*'] == [this_process_lock_file]
  end
  
  # returns true if "we got the lock"
  def wait_for_lock_files_to_stabilize
    start_time = Time.now
    while (elapsed_time = Time.now - start_time) < @synchro_time      
      if !have_lock?
        delete_lock_file # 2 people requested the lock, so both give up (or possibly just 1)
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
  
  def split_to_chunks
    out = []
    current_group = []
    current_sum = 0    
    files_to_chunk = files_incoming(true).sort
    raise 'no files?' if files_to_chunk.empty?
    files_to_chunk.each{|f| 
      file_size = File.size f # work with a '0' for empty dirs, which is ok
      raise 'cannot fit that file ever [yet!] ask for it!' if file_size > @dropbox_size
      if file_size + current_sum > @dropbox_size
        out << [current_group, current_sum]
        current_group = [f]
        current_sum = file_size
      else
        current_group << f
        current_sum += file_size
      end
    }
    out << [current_group, current_sum] unless current_group.empty? # last group
    out
  end
  
  def renamed_being_transferred_dir
    @local_drop_here_to_save_dir + '.being_transferred'
  end
  
  def copy_all_files_over files, relative_to_strip_from_files, to_this_dir  
    sum_transferred = 0
    for filename in files
      relative_extra_dir = filename[(relative_to_strip_from_files.length + 1)..-1] # like "subdir/b"
      new_subdir = to_this_dir + '/' + File.dirname(relative_extra_dir)
      FileUtils.mkdir_p new_subdir # I guess we might be able to use some type of *args to FileUtils.cp_r here?
      if(File.file? filename)
        # avoid jruby 7046 for large files...
        # FileUtils.cp filename, new_subdir
        cmd = %!copy "#{filename.gsub('/', "\\")}" "#{new_subdir.gsub('/', "\\")}" > NUL 2>&1!
        assert system(cmd)     
		sum_transferred += File.size(new_subdir + '/' + File.filename(filename)) # getting a size now should be safe, shouldn't it?
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
	  show_message "transfer directory is dirty from a previous run, please clean it up, or hit ok and leave\nstuff in it to abort current"
	end
	assert Dir[dropbox_temp_transfer_dir + '/*'].length == 0	  
    copy_all_files_over chunk, renamed_being_transferred_dir, dropbox_temp_transfer_dir	
	assert file_size_incoming_from_dropbox == size, "expecting size #{size} and put size #{file_size_incoming_from_dropbox}" # make sure we copied them to the dropbox temp dir right
  end
  
  def copy_files_in_by_chunks
    for chunk, size in split_to_chunks
      copy_chunk_to_dropbox chunk, size
      touch_the_you_can_go_for_it_file size
      wait_for_all_clients_to_copy_files_out
      File.delete previous_you_can_go_for_it_size_file
      FileUtils.rm_rf dropbox_temp_transfer_dir
      Dir.mkdir dropbox_temp_transfer_dir
    end
  end
  
  def delete_lock_file
    File.delete this_process_lock_file
  end
  
  def client_done_copying_files
    Dir[track_when_client_done_dir + '/*']
  end
  
  def wait_for_all_clients_to_copy_files_out
    while client_done_copying_files.length != @total_client_size
      sleep!('wait_for_all_clients_to_copy_files_out')
    end
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
      FileUtils.rm_rf renamed_being_transferred_dir # should be safe... :)
	ensure
      delete_lock_file
	end
	# TODO am I supposed to delete the local files here?
  end
  
  require 'copy_from_server'
 
end