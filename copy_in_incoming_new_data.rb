class IncomingCopier

  def initialize local_drop_here_to_save_dir, dropbox_root_local_dir, longterm_storage_dir, sleep_time, synchro_time, 
        wait_for_all_clients_to_perform_local_dropbox_sync_time, dropbox_size, total_client_size
    @local_drop_here_to_save_dir = File.expand_path local_drop_here_to_save_dir
	@sleep_time = sleep_time
	@dropbox_root_local_dir = File.expand_path dropbox_root_local_dir
	@synchro_time = synchro_time
	@dropbox_size = dropbox_size
	@wait_for_all_clients_to_perform_local_dropbox_sync_time = wait_for_all_clients_to_perform_local_dropbox_sync_time
	@total_client_size = total_client_size
	@longterm_storage_dir = longterm_storage_dir
    FileUtils.mkdir_p lock_dir
    FileUtils.mkdir_p dropbox_temp_transfer_dir
    FileUtils.mkdir_p track_when_client_done_dir
    @transfer_count = 0
  end
  
  attr_accessor :sleep_time
  
  def dropbox_temp_transfer_dir
    "#{@dropbox_root_local_dir}/temp_transfer"
  end
  
  def lock_dir
    "#{@dropbox_root_local_dir}/synchronization"
  end
  
  def track_when_client_done_dir
    "#{@dropbox_root_local_dir}/track_who_is_done_dir"
  end
  
  def sleep!
    sleep @sleep_time
  end
  
  def files_incoming(use_temp_renamed_local_dir = false)
    if use_temp_renamed_local_dir
      dir = renamed_being_transferred_dir
	else
	  dir = @local_drop_here_to_save_dir
	end
    Dir[dir + '/**/*'].reject{|f| File.directory? f}
  end

  def wait_for_any_files_to_appear
    while files_incoming.length == 0
      sleep!
	  print ','
    end
  end

  def size_incoming_files
    sum = 0; files_incoming.each{|f| sum += File.size f}; sum  
  end
  
  def wait_for_incoming_files_to_stabilize_and_rename
    old_size = -1
	current_size = size_incoming_files
    while(current_size != old_size) 
      old_size = current_size
      sleep!
	  print '-'
	  current_size = size_incoming_files
    end
	assert !File.directory?(renamed_being_transferred_dir)
	FileUtils.mv @local_drop_here_to_save_dir, renamed_being_transferred_dir
	Dir.mkdir @local_drop_here_to_save_dir
  end
  
  def this_process_lock_file
    "#{@dropbox_root_local_dir}/synchronization/request_#{Process.pid}.lock"
  end
  
  def previous_you_can_go_for_it_file
    "#{@dropbox_root_local_dir}/synchronization/begin_transfer_courtesy_#{Process.pid}_#{@transfer_count}"
  end
  
  def you_can_go_for_it_file
    "#{@dropbox_root_local_dir}/synchronization/begin_transfer_courtesy_#{Process.pid}_#{@transfer_count += 1}"
  end
  
  def touch_the_you_can_go_for_it_file
    assert have_lock?, "not locked?"
	assert client_done_copying_files.length == 0 # just in case :P
    FileUtils.touch you_can_go_for_it_file
  end
  
  def wait_if_already_has_lock_files
    raise 'locking confusion detected' if File.exist? this_process_lock_file
    while Dir[lock_dir + '/*'].length > 0
	  sleep!
	  print 'l'
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
    while Time.now - start_time < @synchro_time	  
	  if !have_lock?
	    delete_lock_file
	    return false
	  else
  	    print 'l-'
	    sleep!
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
	  file_size = File.size f
	  raise 'cannot fit that file ever [yet!]' if file_size > @dropbox_size
	  if file_size + current_sum > @dropbox_size
	    out << current_group
		current_group = [f]
		current_sum = file_size
	  else
	    current_group << f
		current_sum += file_size
	  end
	}
	out << current_group unless current_group.empty? # last group
	out
  end
  
  def renamed_being_transferred_dir
    @local_drop_here_to_save_dir + '.being_transferred'
  end
  
  def copy_chunk_in chunk
  	for filename in chunk
	  relative_extra_dir = filename[(renamed_being_transferred_dir.length + 1)..-1] # like "subdir/b"
	  possibly_new_subdir = dropbox_temp_transfer_dir + '/' + File.dirname(relative_extra_dir)
	  FileUtils.mkdir_p possibly_new_subdir # sooo lazy, also, could we use FileUtils.cp_r here?
	  FileUtils.cp filename, possibly_new_subdir
	end
  end
  
  def copy_files_in_by_chunks
    for chunk in split_to_chunks
	  copy_chunk_in chunk
  	  wait_for_all_clients_to_perform_local_dropbox_sync
	  touch_the_you_can_go_for_it_file
	  wait_for_all_clients_to_copy_files_out
	  File.delete previous_you_can_go_for_it_file
	  FileUtils.rm_rf dropbox_temp_transfer_dir
	  Dir.mkdir dropbox_temp_transfer_dir
	end
  end
  
  def delete_lock_file
    File.delete this_process_lock_file
  end
  
  def wait_for_all_clients_to_perform_local_dropbox_sync
    sleep @wait_for_all_clients_to_perform_local_dropbox_sync_time  
  end
  
  def client_done_copying_files
    Dir[track_when_client_done_dir + '/*']
  end
  
  def wait_for_all_clients_to_copy_files_out
    while client_done_copying_files.length != @total_client_size
	  print 'z'
	  sleep!
	end
	for file in client_done_copying_files
	  File.delete file
	end
  end

  def go_single_transfer
    wait_for_any_files_to_appear
	wait_for_incoming_files_to_stabilize_and_rename
	obtain_lock
	copy_files_in_by_chunks
	delete_lock_file
	FileUtils.rm_rf renamed_being_transferred_dir # should be safe... :)
  end
  
  def wait_for_transfer_file_come_up
    while (files = Dir["#{@dropbox_root_local_dir}/synchronization/begin_transfer_courtesy_*"]).length == 0
	  print 'c'
	  sleep!
	end
	@current_transfer_file = files[0]	
  end
  
  def copy_current_files_to_local_permanent_storage
    FileUtils.cp_r dropbox_temp_transfer_dir + '/.', @longterm_storage_dir	
  end
  
  def create_done_copying_files_to_local_file
    FileUtils.touch track_when_client_done_dir + "/done_with_#{File.filename @current_transfer_file}" # LODO use
  end
  
  def wait_till_current_transfer_is_over
    assert File.exist? @current_transfer_file
    while File.exist? @current_transfer_file
	  print 'w'
	  sleep!
	end
  end
  
  def go_single_transfer_in
    wait_for_transfer_file_come_up
	copy_current_files_to_local_permanent_storage
	create_done_copying_files_to_local_file
	wait_till_current_transfer_is_over
  end
  
 
end