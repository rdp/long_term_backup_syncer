
class IncomingCopier

  def current_transfer_ready_files
    Dir["#{@dropbox_root_local_dir}/synchronization/begin_transfer_courtesy_*"]
  end
  
  @shutdown = false
  attr_accessor :shutdown
  def shutdown!
    @shutdown = true
  end

  def wait_for_transfer_file_come_up
    while (files = current_transfer_ready_files).length == 0
      sleep!('wait_for_transfer_file_come_up')
      if @shutdown
        raise 'shutting down' # should be safe here...
      end
    end
    raise files.inspect + " should be size 1?" if files.length != 1
    @current_transfer_file = files[0]    
  end
  
  def wait_for_the_data_to_all_get_here
    @current_transfer_file =~ /.*_(\d+)/
    length_expected = $1.to_i
    while((length = file_size_incoming_from_dropbox) < length_expected)
      sleep!("wait_for_the_data_to_all_get_here #{length.as_gig} < #{length_expected.as_gig}")
    end
    assert file_size_incoming_from_dropbox == length_expected # not greater than it yikes!
	length_expected
  end
  
  def file_size_incoming_from_dropbox
    length = 0
    Dir[dropbox_temp_transfer_dir + '/**/*'].each{|f|
      length += File.size(f) if File.file?(f)
    }
    length
  end  
  
  def copy_files_from_dropbox_to_local_permanent_storage size_expected
    # FileUtils.cp_r dropbox_temp_transfer_dir + '/.', @longterm_storage_dir # avoid jruby file size bug
    transferred = copy_all_files_over Dir[dropbox_temp_transfer_dir + '/**/*'], dropbox_temp_transfer_dir, @longterm_storage_dir, 'from dropbox'
    assert transferred == size_expected
  end
  
  def create_done_copying_files_to_local_file
    FileUtils.touch track_when_client_done_dir + "/done_with_#{File.filename @current_transfer_file}" # LODO use
  end
  
  def wait_till_current_transfer_is_over
    # server might be too fast for us...and delete it before we reach here, possibly
    # assert File.exist? @current_transfer_file
    while File.exist? @current_transfer_file
      sleep!('wait_till_current_transfer_is_over')
    end
  end
  
  # the only one you should have to call...
  def go_single_transfer_in
    wait_for_transfer_file_come_up
    size = wait_for_the_data_to_all_get_here
    copy_files_from_dropbox_to_local_permanent_storage size
    create_done_copying_files_to_local_file
    wait_till_current_transfer_is_over
  end
  
end

class Numeric
  def as_gig
    (self/1e9).round(2).to_s + "GB"
  end
end