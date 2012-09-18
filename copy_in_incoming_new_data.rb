=begin

3. remove lock file
4. wait till "x" clients have each picked it up.
5. delete it
=end

class IncomingCopier

  def initialize local_drop_here_to_save_dir, dropbox_root_local_dir, sleep_time, synchro_time, 
        wait_for_all_clients_to_perform_large_download_time, dropbox_size, total_client_size
    @local_drop_here_to_save_dir = File.expand_path local_drop_here_to_save_dir
	@sleep_time = sleep_time
	@dropbox_root_local_dir = File.expand_path dropbox_root_local_dir
	@synchro_time = synchro_time
	@dropbox_size = dropbox_size
	@wait_for_all_clients_to_perform_large_download_time = wait_for_all_clients_to_perform_large_download_time
	@total_client_size = total_client_size
    FileUtils.mkdir_p lock_dir
    FileUtils.mkdir_p dropbox_temp_transfer_dir
    FileUtils.mkdir_p track_when_done_dir
  end
  
  attr_accessor :sleep_time
  
  def dropbox_temp_transfer_dir
    "#{@dropbox_root_local_dir}/temp_transfer"
  end
  
  def lock_dir
    "#{@dropbox_root_local_dir}/synchronization"
  end
  
  def track_when_done_dir
    "#{@dropbox_root_local_dir}/track_who_is_done_dir"
  end
  
  def sleep!
    sleep @sleep_time
  end
  
  def files_incoming(use_temp_renamed_local_dir = false)
    if use_temp_renamed_local_dir
      dir = @local_drop_here_to_save_dir + ".being_transferred"
	else
	  dir = @local_drop_here_to_save_dir
	end
    Dir[dir + '/**/*'].reject{|f| File.directory? f}
  end

  def wait_for_files_to_appear
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
	FileUtils.mv @local_drop_here_to_save_dir, @local_drop_here_to_save_dir + ".being_transferred"
	Dir.mkdir @local_drop_here_to_save_dir
  end
  
  def this_process_lock_file
    "#{@dropbox_root_local_dir}/synchronization/request_#{Process.pid}.lock"
  end
  
  def wait_if_already_has_lock_files
    raise 'locking confusion detected' if File.exist? this_process_lock_file
    while Dir[lock_dir + '/*'].length > 0
	  sleep!
	end
  end
  
  def create_lock_file
    FileUtils.touch this_process_lock_file    
  end
  
  # returns true if "we got the lock"
  def wait_for_lock_files_to_stabilize
    start_time = Time.now
    while Time.now - start_time < @synchro_time
	  if Dir[lock_dir + '/*'] != [this_process_lock_file]
	    delete_lock_file
	    return false
	  else
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
  
  def copy_files_in_by_chunks
    for chunk in split_to_chunks
	  for filename in chunk
	    relative_extra_dir = filename[((@local_drop_here_to_save_dir + '.being_transferred').length + 1)..-1] # like "subdir/b"
		new_subdir = dropbox_temp_transfer_dir + '/' + File.dirname(relative_extra_dir)
		FileUtils.mkdir_p new_subdir
		FileUtils.cp filename, new_subdir		
	  end
	end
  end
  
  def delete_lock_file
    File.delete this_process_lock_file
  end
  
  def wait_for_all_clients_to_perform_large_download
    sleep @wait_for_all_clients_to_perform_large_download_time  
  end
  
  def client_done_copying_files
    Dir[track_when_done_dir + '/*']
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
    wait_for_files_to_appear
	wait_for_incoming_files_to_stabilize_and_rename
	obtain_lock
	copy_files_in_by_chunks
	wait_for_all_clients_to_perform_large_download
	wait_for_all_clients_to_copy_files_out
	delete_lock_file # allow them to copy it TODO umm...should we wait awhile?
  end
  
end