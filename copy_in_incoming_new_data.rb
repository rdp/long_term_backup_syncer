=begin

0. notice incoming files
0.5 sleep a bit to make sure there aren't more coming...
1. create lock file, wait
2. copy in "a chunk"
  split files for now
2.5 create "1 client has it"
3. remove lock file
4. wait till "x" clients have each picked it up.
5. delete it
=end

class IncomingCopier

  def initialize local_drop_here_to_save_dir, sleep_time
    @local_drop_here_to_save_dir = local_drop_here_to_save_dir
	@sleep_time = sleep_time
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
	  print '.'
    end
  end

  def size_incoming_files
    sum = 0; files_incoming.each{|f| sum += File.size f}; sum  
  end
  
  def wait_for_incoming_files_to_stabilize
    old_size = 0
	current_size = size_incoming_files
    while(current_size != old_size) 
      old_size = current_size
      sleep!
	  current_size = size_incoming_files
    end
  end
  
end