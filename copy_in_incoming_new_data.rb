=begin

2. copy in "a chunk"
2.5 create "1 client has it"
3. remove lock file
4. wait till "x" clients have each picked it up.
5. delete it
=end

class IncomingCopier

  def initialize local_drop_here_to_save_dir, dropbox_root_local_dir, sleep_time, synchro_time, dropbox_size
    @local_drop_here_to_save_dir = local_drop_here_to_save_dir
	@sleep_time = sleep_time
	@dropbox_root_local_dir = dropbox_root_local_dir
	@synchro_time = synchro_time
	@dropbox_size = dropbox_size
    Dir.mkdir lock_dir unless File.directory?(lock_dir)
  end
  
  attr_accessor :sleep_time
  
  def lock_dir
    "#{@dropbox_root_local_dir}/synchronization"
  end
  
  def sleep!
    sleep @sleep_time
  end
  
  def files_incoming
    Dir[@local_drop_here_to_save_dir + '/**/*']
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
  
  def wait_for_incoming_files_to_stabilize
    old_size = -1
	current_size = size_incoming_files
    while(current_size != old_size) 
      old_size = current_size
      sleep!
	  print '-'
	  current_size = size_incoming_files
    end
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
	    File.delete this_process_lock_file # should be there...
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
    files_incoming.sort.each{|f| 
	  file_size = File.size f
	  raise 'cannot fit that file ever [yet!]' if file_size > @dropbox_size
	  if File.size(f) +  current_sum > @dropbox_size
	    out << current_group
		current_group = [f]
		current_sum = 0
	  else
	     out << current_group
	  end
	}
	out
  end
 
  def go
    wait_for_files_to_appear
	wait_for_incoming_files_to_stabilize
	obtain_lock
  end
  
end