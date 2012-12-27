
class IncomingCopier

  def current_transfer_ready_files
    Dir["#{@dropbox_root_local_dir}/synchronization/begin_transfer_courtesy_*"]
  end

  def wait_for_transfer_file_come_up
    while (files = current_transfer_ready_files).length == 0
	  sleep!
	  print 'c'
	end
	raise files.inspect + " should be size 1?" if files.length != 1
	@current_transfer_file = files[0]	
  end
  
  def copy_current_files_to_local_permanent_storage
    FileUtils.cp_r dropbox_temp_transfer_dir + '/.', @longterm_storage_dir	
  end
  
  def create_done_copying_files_to_local_file
    FileUtils.touch track_when_client_done_dir + "/done_with_#{File.filename @current_transfer_file}" # LODO use
  end
  
  def wait_till_current_transfer_is_over
    # server might be too fast for us...maybe
	# assert File.exist? @current_transfer_file
    while File.exist? @current_transfer_file
	  print 'w'
	  sleep!
	end
  end
  
  # the only one you should have to call...
  def go_single_transfer_in
    wait_for_transfer_file_come_up
	copy_current_files_to_local_permanent_storage
	create_done_copying_files_to_local_file
	wait_till_current_transfer_is_over
  end
  
end