
class IncomingCopier

  def current_transfer_ready_files
    Dir["#{lock_dir}/begin_transfer_courtesy_*"]
  end
  
  attr_accessor :shutdown
  def shutdown!
    @shutdown = true
  end

  def wait_for_transfer_file_come_up
    assert @current_transfer_file == nil
    while (files = current_transfer_ready_files).length == 0
      sleep! :client, 'wait_for_next_transfer_ready_file_to_appear'
      if @shutdown
        raise 'shutting down' # should be safe here...
      end
    end
    raise files.inspect + " should have been only size 1!?" if files.length != 1
    @current_transfer_file = files[0]
  end
  
  def wait_for_the_data_to_all_get_here
    @current_transfer_file =~ /.*_(\d+)/
    length_expected = $1.to_i
    while((length = file_size_incoming_from_dropbox) < length_expected)
      sleep! :client, "wait_for_the_data_to_all_get_here #{length.as_gig} < #{length_expected.as_gig}"
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
    sleep!(:client, "copying files from network to local long term repo", 0)
    # FileUtils.cp_r dropbox_temp_transfer_dir + '/.', @longterm_storage_dir # we want to have the glob...
    files_to_copy = Dir[dropbox_temp_transfer_dir + '/**/*']
    transferred, files_copied = copy_files_over files_to_copy, dropbox_temp_transfer_dir, @longterm_storage_dir, :client
    assert transferred == size_expected
    files_copied
  end
  
  def recombinate_files_split_piece_wise filenames
    regex = /^(.+)___piece_(\d+)_of_(\d+)_total_size_(\d+)_md5_(.*)$/
    filenames_to_recombo = filenames.select{|f| f =~ regex}.sort_by{|f| f =~ regex; [$1, Integer($2)]}
    previous_number = nil
    previous_name = nil
    previous_total_size = nil
    previous_md5 = nil
    current_handle = nil
    current_total_pieces_number = nil
    for filename in filenames_to_recombo          
      sleep!(:client, "recombinating file #{filename}", 0)
      filename =~ regex
      incoming_filename = $1
      assert File.size(filename) > 0 # that would be weird...
      this_piece_number = Integer($2)
      total_pieces_number = Integer($3)
      total_size = Integer($4)
      file_md5 = $5
      assert total_pieces_number > 0 # that would be unexpected...
      
      if current_handle
        assert this_piece_number > 0
        assert this_piece_number == previous_number + 1
        assert incoming_filename == previous_name
        assert total_size == previous_total_size
        assert file_md5 == previous_md5
        assert total_pieces_number == current_total_pieces_number # should always match..
        previous_number = this_piece_number
        # rest don't need to change...
      else
        assert this_piece_number == 0
        assert previous_number == nil
        previous_number = 0
        assert previous_md5 == nil
        previous_md5 = file_md5
        assert previous_name == nil
        assert previous_total_size == nil
        assert current_total_pieces_number == nil
        previous_name = incoming_filename
        previous_total_size = total_size
        current_handle = File.open(incoming_filename, 'ab') # append binary
        current_total_pieces_number = total_pieces_number
      end
      
      chunk_size = 100*1024*1024 # 100 MB chunks to avoid out of heap errors...
      File.open(filename, 'rb') do |f|
        while !f.eof?
          current_handle.write(f.read chunk_size)
        end
      end
      
      if total_pieces_number == this_piece_number
        current_handle.close
        current_handle = nil
        size = File.size(incoming_filename)
        if size != previous_total_size
          raise "size of recombo file mismatch?"
        end
        if (md5 = Digest::MD5.file(incoming_filename)) != previous_md5
          raise "md5 recombo mismatch? #{md5} #{previous_md5}"
        end
        previous_md5 = nil
        previous_number = nil
        previous_name = nil
        current_handle = nil
        previous_total_size = nil
        current_total_pieces_number = nil
      end
    end
    
    assert current_handle == nil # should have been already closed...
    filenames_to_recombo.each{|f| File.delete f} # don't want the old partial files anymore...
    ensure
      current_handle.close if current_handle # error condition
  end
  
  attr_accessor :extra_stuff_for_done_file # for multiple instances, in unit tests, to be able to differentiate themselves in stop file name
  
  def create_done_copying_files_to_local_file
    path = track_when_client_done_dir + "/done_with_#{File.filename @current_transfer_file}_#{Socket.gethostname}#{extra_stuff_for_done_file}"
    if File.exist? path
      raise "file already exists #{path}?!"
    end
    sleep! :client, "touching done file #{path}", 0
    FileUtils.touch path
  end
  
  def wait_till_current_transfer_is_over
    # server might be too fast for us...and delete it before we reach here, possibly
    # assert File.exist? @current_transfer_file
    while File.exist? @current_transfer_file
      sleep!(:client, 'wait_till_current_transfer_is_deemed_over_by_sender ' + File.filename(@current_transfer_file))
    end
  end
  
  # this concept of delineating a batch/group of transfers...totally scares me yikes! maybe make a group manifest for it?
  def recombinate_files_for_multiple_transfers_possibly
    got_end_big_transfer = false
      if @current_transfer_file =~ /recombinate_ok/
      recombinate_files_split_piece_wise @copied_files
      @copied_files = []
      got_end_big_transfer = true
    end
    @current_transfer_file = nil
    got_end_big_transfer
  end
  
  # the only one you should have to call...
  def go_single_transfer_in
    wait_for_transfer_file_come_up
    size = wait_for_the_data_to_all_get_here
    @copied_files += copy_files_from_dropbox_to_local_permanent_storage size
    create_done_copying_files_to_local_file
    wait_till_current_transfer_is_over
    return recombinate_files_for_multiple_transfers_possibly
  end
  
end

class Numeric
  def as_gig
    (self/1e9).round(2).to_s + "GB"
  end
end