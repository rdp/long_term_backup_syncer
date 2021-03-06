require 'fileutils'
require 'simple_gui_creator' # we use it inline now
require 'digest/md5'

class IncomingCopier

  def initialize local_drop_here_to_save_dir, dropbox_root_local_dir, longterm_storage_dir, sleep_time, synchro_time, 
        dropbox_size, total_client_size
    @local_drop_here_to_save_dir = File.expand_path local_drop_here_to_save_dir
    @sleep_time = sleep_time
    @dropbox_root_local_dir = File.expand_path dropbox_root_local_dir
    @synchro_time = synchro_time
    @dropbox_size = dropbox_size
    @total_client_size = total_client_size
	assert total_client_size > 0
    @longterm_storage_dir = longterm_storage_dir
    FileUtils.mkdir_p lock_dir
    FileUtils.mkdir_p dropbox_temp_transfer_dir
    FileUtils.mkdir_p track_when_client_done_dir
    @transfer_count = 0
    @prompt_before_uploading = nil
	@shutdown = false
	@copied_files = []
  end
  
  # most of these for unit tests...
  attr_accessor :sleep_time
  attr_reader :longterm_storage_dir
  attr_accessor :prompt_before_uploading
  attr_accessor :send_updates_here
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
    "#{@dropbox_root_local_dir}/backup_syncer/synchronization/track_which_clients_are_done_dir" # subdir to be less uhgly
  end
  
  def sleep!(type, output_message, sleep_time=@sleep_time)
    sleep sleep_time
	if send_updates_here
	  send_updates_here.call type, output_message
	end
    print "#{type}: #{output_message}." unless quiet_mode
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
      sleep!(:server, 'wait_for_any_files_to_appear')
      if @shutdown
        raise 'shutting down' # a safe place to quit...
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
        if show_select_buttons_prompt("appears there was an interrupted transfer, would you like to restage it for re-transfer?") == :yes
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
  
  def wait_for_incoming_files_prompt_and_rename_entire_dir
    sleep!(:server, 'wait_for_prompt_confirmation')
    if @prompt_before_uploading
      @prompt_before_uploading.call
    end    
    if File.directory?(renamed_being_transferred_dir) # should have been cleaned up already [!]...
	  raise "renamed_being_transferred_dir already exists? #{renamed_being_transferred_dir}"
	end
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
  
  def next_you_can_go_for_it_after_size_file current_chunk_size, end_of_a_batch
    # use filename instead of size, to make it synchronously created with its contents :)
    @previous_go_for_it_filename = "#{lock_dir}/begin_transfer_courtesy_#{Socket.gethostname}_#{Process.pid}_#{@transfer_count += 1}_#{end_of_a_batch ? 'recombinate_ok' : ''}_#{current_chunk_size}"
  end
  
  def sanity_check_clean_and_locked
    assert have_lock?, "should be locked"
	# we have the lock, so we control these files, and none should be there yet :)
    if client_done_copying_files.length != 0
	  if show_select_buttons_prompt("detected some orphaned 'transfer done' files, delete them?\n#{client_done_copying_files}") == :yes
	    client_done_copying_files.each{|f| File.delete(f) }
      else
	    raise 'dunno what to do here'
	  end
	end
    if current_transfer_ready_files.length != 0
	  if show_select_buttons_prompt("detected some orphaned 'transfer read' files, delete them?\n#{current_transfer_ready_files}") == :yes
	    current_transfer_ready_files.each{|f| File.delete(f) }
	  else
	    raise 'dunno how to proceed'	  
	  end	
	end
  end
    
  def touch_the_you_can_go_for_it_file current_chunk_size, end_of_a_batch
    sanity_check_clean_and_locked
    FileUtils.touch next_you_can_go_for_it_after_size_file(current_chunk_size, end_of_a_batch)
  end
  
  def all_lock_files
    Dir[lock_dir + '/*.lock']  
  end
  
  def wait_if_already_has_lock_files
    if old_lock_files_this_box.length > 0
      if show_select_buttons_prompt("found some apparent old lock synchronization files that originated from this local box, they're probably orphaned old junk, delete them?\n#{old_lock_files_this_box.join(', ')}") == :yes
        old_lock_files_this_box.each{|f| File.delete(f) }
      end
    end
    while all_lock_files.length > 0
      raise 'double locking confusion?' if File.exist? this_process_lock_file
      sleep!(:server, 'waiting for old lock files to disappear ' + all_lock_files.join(' '))
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
        delete_lock_file # 2 people requested the lock, so both give up (or possibly just this 1 gives up, hopefully thread safe)
        return false
      else
        sleep!(:server, "wait_for_lock_files_to_stabilize #{elapsed_time} < #{@synchro_time}")
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
	sleep!(:server, "lock obtained/locked!")
  end
  
  def split_up_large_file filename
    size = 0
	file_size = File.size filename
    sleep!(:server, "calculating md5 for large file .../#{File.basename(filename)}", 0)
	file_md5 = Digest::MD5.file(filename)
	pieces_total = (file_size / @dropbox_size.to_f).ceil
	pieces_total -= 1 # we want it as 0_of_1 and 1_of_1 (even though there are 2 total...
	pieces = []
	file_count = 0
	File.open(filename, 'rb') do |from_file|
	  while size < file_size
	    piece_filename = "#{filename}___piece_#{file_count}_of_#{pieces_total}_total_size_#{file_size}_md5_#{file_md5}"
        sleep!(:server, "splitting up large file .../#{File.basename(filename)} #{file_count+1}/#{pieces_total}", 0)
	    File.open(piece_filename, 'wb') do |to_file|
		  local_chunk_size = 1024*1024*128 # 128 MB reads, to avoid running out of Heap if you read 2.5GB at a time...
		  amount_read = 0
		  while(amount_read < @dropbox_size && !from_file.eof?)
		    amount_to_read = [local_chunk_size, @dropbox_size - amount_read].min # try not to go over the dropbox size for chunking, while reading it piece-meal...
	        amount_read += to_file.write(from_file.read(amount_to_read))
		  end
		  size += amount_read
		  file_count += 1
	    end
		pieces << piece_filename
	  end
	end
    FileUtils.rm filename # I guess it's safe since we have all the pieces at least, and if we restart, it should still recombine them...
	pieces
  end
  
  def split_up_too_large_of_files
    all_pieces = [] # for unit tests
    for potentially_big_file in files_incoming(true)
	  # raise "dirty old partial file" if potentially_big_file =~ /___piece_/ # this is actually ok in the case of an interrupted transfer where the file was already split LODO keep the original big files, and delete these, and re-split, in that case, I think...since it confuses people to death to see their beautiful files mangled LOL
	  if File.size(potentially_big_file) > @dropbox_size
	    all_pieces += split_up_large_file(potentially_big_file)
	  end
	end
	all_pieces
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
      raise "we should have already split up this file!" if file_size > @dropbox_size
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
  
  raise 'old jruby version detected!' unless JRUBY_VERSION >= '1.7.2' # avoid JRUBY-7046 here or there...
  
  def renamed_being_transferred_dir
    @local_drop_here_to_save_dir + '.being_transferred'
  end
  
  def copy_files_over files, relative_to_strip_from_files, to_this_dir, type
    sum_transferred = 0
	new_transferred_names = []
    for filename in files
      relative_extra_dir = filename[(relative_to_strip_from_files.length + 1)..-1] # like "subdir/b"
      new_subdir = to_this_dir + '/' + File.dirname(relative_extra_dir)
      FileUtils.mkdir_p new_subdir # I guess we might be able to use some type of *args to FileUtils.cp_r here?
      if(File.file? filename)
        FileUtils.cp filename, new_subdir
        sleep!(type, 'copy_files_over', 0) # status update :) 
        new_filename = new_subdir + '/' + File.filename(filename)
        sum_transferred += File.size(new_filename) # getting a file size after copy should be safe, shouldn't it?
		new_transferred_names << new_filename
      else
        assert File.directory?(filename)
        FileUtils.mkdir_p new_subdir + '/' + relative_extra_dir
      end
    end
    [sum_transferred, new_transferred_names]
  end
  
  def copy_chunk_to_dropbox chunk, size
    if Dir[dropbox_temp_transfer_dir + '/*'].length != 0
      show_in_explorer dropbox_temp_transfer_dir
      show_message "transfer directory is dirty from a previous run, please clean it up, and del it\nor hit ok and leave stuff in it to abort current transfer (or touch trust_dropbox file)"
      assert Dir[dropbox_temp_transfer_dir + '/*'].length == 0, "shared temp transfer drop dir had some unknown files in it?"
    end
    copy_files_over chunk, renamed_being_transferred_dir, dropbox_temp_transfer_dir, :server
    assert file_size_incoming_from_dropbox == size, "expecting size #{size} but put size #{file_size_incoming_from_dropbox}"
  end
  
  def do_full_chunk_to_clients chunk, size, idx, chunks_total_size
    copy_chunk_to_dropbox chunk, size
    touch_the_you_can_go_for_it_file size, (idx == chunks_total_size - 1)
    wait_for_all_clients_to_copy_files_out idx, chunks_total_size
	assert File.file? previous_you_can_go_for_it_size_file # it should still be there
    File.delete previous_you_can_go_for_it_size_file
    clear_dir_looping dropbox_temp_transfer_dir
  end
  
  def copy_files_in_by_chunks
    # we retain the lock the whole time...so it's safe for us to send files in random order, then tell the clients to recombinate
	# maybe we should just touch a 'you can recombinate file' when we're done...
    sanity_check_clean_and_locked
	split_up_too_large_of_files
	chunks = split_to_chunks
	chunks.each_with_index{|(chunk, size), idx|
	  sleep!(:server, "copying to network store chunk #{idx+1} of #{chunks.size}", 0)
	  do_full_chunk_to_clients chunk, size, idx, chunks.size
    }
  end
  
  def clear_dir_looping dir
    sleep!(:server, "clearing the temp transfer folder", 0)
	while File.directory? dir # sometimes dropbox has a handle on things when you try and delete them, so you can't...well at least this can happen in IT tests anyway
	  FileUtils.rm_rf dir
	end
	begin
      Dir.mkdir dir
	rescue Errno::EIO => folder_busy # google drive did this... 
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
  
  def wait_for_all_clients_to_copy_files_out idx, chunks_total_size
    while (got = client_done_copying_files.length) != @total_client_size
      sleep! :server, "wait_for_all_clients_to_copy_files_out #{got} < #{@total_client_size} for chunk #{idx + 1} of #{chunks_total_size}"
    end
	sleep! :server, "detected all clients are done, deleting their notification files", 0
    for file in client_done_copying_files
      begin
	    File.delete file
      rescue Errno::EACCES => file_being_touched_right_now # mostly for unit tests...
	    p 'retrying delete ' + file
	    retry
	  end
	  p 'deletec', file, File.exist?(file)
    end
  end

  # the only one you should call...
  def go_single_transfer_out
    wait_for_any_files_to_appear
    wait_for_incoming_files_prompt_and_rename_entire_dir
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