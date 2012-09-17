=begin

1. create lock file, wait
2. copy in "a chunk"
  split files for now
2.5 create "1 client has it"
3. remove lock file
4. wait till "x" clients have each picked it up.
5. delete it
=end

class IncomingCopier

  def initialize local_drop_here_to_save_dir, dropbox_root_local_dir, sleep_time
    @local_drop_here_to_save_dir = local_drop_here_to_save_dir
	@sleep_time = sleep_time
	@dropbox_root_local_dir = dropbox_root_local_dir
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
    100.times { sleep! } # TODO meter this ...
	if Dir[lock_dir + '/*'].reject{|file| file == this_process_lock_file}.length > 0
	  return false
	else
	  return true
	end
  end
  
  def obtain_lock
	got_it = false
	while !got_it
	  wait_if_already_has_lock_files
	  create_lock_file
	  got_it = wait_for_lock_files_to_stabilize
	end
  end
 
  def go
    wait_for_files_to_appear
	wait_for_incoming_files_to_stabilize
	obtain_lock
  end
  
end