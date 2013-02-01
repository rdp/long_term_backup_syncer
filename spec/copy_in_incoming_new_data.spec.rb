require 'rubygems' # rspec
require 'rspec/autorun'
$: << File.dirname(__FILE__) + "/../lib"
# gems
for dir in Dir[File.dirname(__FILE__) + "/../vendor/**/lib"]
  $: << dir
end
require 'sane'
require 'copy_data_to_server.rb'
require 'fileutils'

describe IncomingCopier do

  before do
    FileUtils.rm_rf 'test_dir'
    Dir.mkdir 'test_dir'
    FileUtils.rm_rf 'test_dir.being_transferred'
    FileUtils.rm_rf 'dropbox_root_dir'
    FileUtils.rm_rf 'longterm_storage'
    Dir.mkdir 'dropbox_root_dir'
    Dir.mkdir 'longterm_storage'
    @subject = IncomingCopier.new 'test_dir', 'dropbox_root_dir', 'longterm_storage', 0.1, 0.5, 1000, 1
	@subject.quiet_mode = true
    @competitor = "dropbox_root_dir/backup_syncer/synchronization/some_other_process.lock"
  end

  it 'should wait for incoming data' do
    t = time_in_other_thread { @subject.wait_for_any_files_to_appear }
    sleep 0.3
    FileUtils.touch 'test_dir/a'
    t.join
    @thread_took.should be > 0.3
  end
  
  it 'should rename dir' do
    File.write 'test_dir/a', 'some stuff'
	got_it = false
	@subject.prompt_before_uploading = proc {
	  got_it = true
	}
    @subject.wait_for_incoming_files_and_rename_entire_dir
	assert got_it
    assert File.directory?('test_dir.being_transferred')
    assert File.exist?('test_dir.being_transferred/a')
  end
  
  def its_lock_file
    @subject.this_process_lock_file
  end
  
  it 'should create a lock file' do
    assert !File.exist?(its_lock_file)
    @subject.create_lock_file
    assert File.exist?(its_lock_file)
  end
  
  it 'should back off if already locked' do
    FileUtils.touch @competitor
    t = time_in_other_thread { @subject.wait_if_already_has_lock_files }
    sleep 0.3
    File.delete @competitor
    t.join
    @thread_took.should be > 0.3
  end
  
  it 'should back off if lock file contention' do
    FileUtils.touch @competitor
    @subject.sleep_time = 0.01
    @subject.create_lock_file
    assert !@subject.wait_for_lock_files_to_stabilize
    assert !File.exist?(its_lock_file)
    File.delete @competitor
    @subject.create_lock_file
    assert @subject.wait_for_lock_files_to_stabilize
    assert File.exist?(its_lock_file) # doesn't delete it this time
  end
  
  it 'should retry when it detects contention' do
    start_time = Time.now
    t = time_in_other_thread { @subject.obtain_lock }    
    sleep 0.1
    while(Time.now - start_time < 0.75)
        FileUtils.touch @competitor
      sleep 0.1
      File.delete @competitor
      sleep 0.1
    end
    t.join
    @thread_took.should be > 0.75
  end

  it 'should split incoming data to transferrable chunks' do
    proc { @subject.split_to_chunks}.should raise_exception(/no files/)
    test_dir = File.expand_path 'test_dir.being_transferred'
    Dir.mkdir test_dir
    a = test_dir + '/a'
    b = test_dir + '/b'
    c = test_dir + '/c'
    d = test_dir + '/d'
    e = test_dir + '/e'
    File.write a, '_'
    @subject.split_to_chunks.should == [[[a], 1]]
    File.write b, '_'
    @subject.split_to_chunks.should == [[[a, b], 2]]
    File.write c, '_'*1000
    @subject.split_to_chunks.should == [[[a, b], 2], [[c], 1000]]
    File.write d, '_'*100
    @subject.split_to_chunks.should == [[[a, b], 2], [[c], 1000], [[d], 100]]
    File.write e, '_'*800
    @subject.split_to_chunks.should == [[[a, b], 2], [[c], 1000], [[d, e], 900]]
  end

  def create_block_done_files
    FileUtils.touch @subject.track_when_client_done_dir + '/client1_is_done'
  end  
  
  it 'should copy files in' do
    test_dir = File.expand_path '/tmp/test_dir.being_transferred'
    begin
      Dir.mkdir test_dir
      subject = IncomingCopier.new '/tmp/test_dir', 'dropbox_root_dir', 'longterm', 0.1, 0.5, 1000, 2
      FileUtils.mkdir_p test_dir + '/subdir'
      FileUtils.mkdir_p test_dir + '/subdir2'
      File.write test_dir + '/a', '_'
      File.write test_dir + '/subdir/b', '_'
      subject.create_lock_file
      assert !File.exist?("dropbox_root_dir/backup_syncer/temp_transfer_big_dir/a")
      t = Thread.new { subject.copy_chunk_to_dropbox [test_dir + '/a', test_dir + '/subdir/b', test_dir + '/subdir2'], 2 }
      sleep 0.2
      create_block_done_files    
      t.join
      assert File.exist? "dropbox_root_dir/backup_syncer/temp_transfer_big_dir/a"
      assert File.exist? "dropbox_root_dir/backup_syncer/temp_transfer_big_dir/subdir/b"
      assert File.directory? "dropbox_root_dir/backup_syncer/temp_transfer_big_dir/subdir2" # empty dir
    ensure
      FileUtils.rm_rf test_dir
    end    
  end
  
  def create_a_few_files_in_to_transfer_dir
    File.write 'test_dir/a', '_'
    Dir.mkdir 'test_dir/subdir'
    File.write 'test_dir/subdir/b', '_' * 1000  
    Dir.mkdir 'test_dir/subdir2' # an empty dir :)
  end
  
  def create_a_few_files_in_dropbox_dir
    FileUtils.mkdir_p "dropbox_root_dir/backup_syncer/temp_transfer_big_dir/subdir"
    File.write 'dropbox_root_dir/backup_syncer/temp_transfer_big_dir/a', '_'
    File.write 'dropbox_root_dir/backup_syncer/temp_transfer_big_dir/subdir/b', '_' * 1000  
    Dir.mkdir 'dropbox_root_dir/backup_syncer/temp_transfer_big_dir/subdir2' # an empty dir :)
  end

  it 'should do a complete multi-chunk transfer' do
    create_a_few_files_in_to_transfer_dir
    assert !File.directory?('dropbox_root_dir/backup_syncer/temp_transfer_big_dir/subdir2')

    t = Thread.new { @subject.go_single_transfer_out }    
    # 2 chunks
    while !File.exist?(@subject.previous_you_can_go_for_it_size_file) # takes quite awhile [LODO check why?...]
      sleep 0.01
    end
    # "sure we got 'em them"
    create_block_done_files
    sleep 0.2 # let it delete block done files, copy in more data LODO check takes this long?
    while !File.exist?(@subject.previous_you_can_go_for_it_size_file) # takes quite awhile [LODO check why?...]
      sleep 0.01
    end
    assert File.directory?('dropbox_root_dir/backup_syncer/temp_transfer_big_dir/subdir2')
    # "sure we got 'em them"
    create_block_done_files
    t.join
    
    assert @subject.client_done_copying_files.length == 0 # it should clean up old client done files
    Dir['dropbox_root_dir/backup_syncer/temp_transfer_big_dir/*'].length.should == 0 # cleaned up drop box after successful transfer
    assert !File.exist?(its_lock_file)
    assert !File.exist?(@subject.previous_you_can_go_for_it_size_file)
    assert !File.exist?('test_dir/a')
    assert !File.exist?('test_dir.being_transferred/a')
    assert !File.exist?('test_dir/subdir')
    assert !File.exist?('test_dir.being_transferred/subdir')
  end
  
  it 'should wait for clients to finish downloading it' do
    @subject = IncomingCopier.new 'test_dir', 'dropbox_root_dir', 'longterm_storage', 0.1, 0.5, 1000, 2
    t = time_in_other_thread { @subject.wait_for_all_clients_to_copy_files_out}
    FileUtils.touch @subject.track_when_client_done_dir + '/a'
    sleep 0.3
    FileUtils.touch @subject.track_when_client_done_dir + '/b'
    t.join
    @thread_took.should be < 1
    @thread_took.should be > 0.3
    assert !File.exist?(@subject.track_when_client_done_dir + '/a')
    assert !File.exist?(@subject.track_when_client_done_dir + '/b')
  end
  
  it 'should touch the you can go for it file' do
    @subject.create_lock_file
    @subject.touch_the_you_can_go_for_it_file(777)
    assert File.exist? @subject.previous_you_can_go_for_it_size_file
    proc { @subject.split_to_chunks }.should raise_exception /no files/
  end

  def time_in_other_thread
    start_time = Time.now
    Thread.new { yield; @thread_took = Time.now - start_time}
  end  
  
  describe 'the client receiver' do
    it 'should be able to wait till it sees that something is ready to transfer' do
      t = time_in_other_thread { @subject.wait_for_transfer_file_come_up }
      sleep 0.3
      FileUtils.touch @subject.next_you_can_go_for_it_after_size_file(767)
      t.join
      @thread_took.should be > 0.3
    end
    
    it 'should wait till enough file bytes appear before performing copy' do
      FileUtils.touch @subject.next_you_can_go_for_it_after_size_file(767)
      @subject.wait_for_transfer_file_come_up # notice it
      t = time_in_other_thread { @subject.wait_for_the_data_to_all_get_here }
      sleep 0.1
       File.write "dropbox_root_dir/backup_syncer/temp_transfer_big_dir/a", '_' * 766
      sleep 0.2
       File.write "dropbox_root_dir/backup_syncer/temp_transfer_big_dir/b", '_' * 1
      t.join
      @thread_took.should be > 0.3    
    end
    
    it 'should bail if you transfer too much' do
      FileUtils.touch @subject.next_you_can_go_for_it_after_size_file(767)
      @subject.wait_for_transfer_file_come_up # notice it
      sleep 0.1 # let it sleep
       File.write "dropbox_root_dir/backup_syncer/temp_transfer_big_dir/a", '_' * 786
      #proc { @subject.wait_for_the_data_to_all_get_here }.should raise_exception(/no files/) # TODO uncomment    
    end
    
    it 'should copy the files over from dropbox to local storage' do      
      create_a_few_files_in_dropbox_dir
      assert !File.exist?('longterm_storage/a')
      @subject.copy_files_from_dropbox_to_local_permanent_storage 1001
      assert File.exist?('longterm_storage/a')  
      assert File.exist?('longterm_storage/subdir/b')
      assert File.directory?('longterm_storage/subdir2')
    end
    
    it 'should create its done file' do
      Dir[@subject.track_when_client_done_dir + '/*'].length.should == 0
      @subject.instance_variable_set(:@current_transfer_file, 'a_transfer')
      @subject.create_done_copying_files_to_local_file
      Dir[@subject.track_when_client_done_dir + '/*'].length.should == 1
    end
    
    it 'should wait until transfer is over with before trying anything else' do
      @subject.instance_variable_set(:@current_transfer_file, 'a_transfer')
      FileUtils.touch 'a_transfer'
      t = time_in_other_thread { @subject.wait_till_current_transfer_is_over }
      sleep 0.3
      File.delete 'a_transfer'
      t.join
      @thread_took.should be > 0.3
    end
    
    it 'should do full client receive loop' do
	  # use the same client sending it to itself.  which is actually what we do in production too LOL
      create_a_few_files_in_to_transfer_dir
      assert !File.exist?(@subject.longterm_storage_dir + '/a') # sanity check test
      t = Thread.new { @subject.go_single_transfer_out }
      @subject.go_single_transfer_in
      @subject.go_single_transfer_in
      t.join
      assert File.exist?(@subject.longterm_storage_dir + '/a') # single root file
      assert File.exist?(@subject.longterm_storage_dir + '/subdir/b') # subdir with file
      assert File.directory?(@subject.longterm_storage_dir + '/subdir2') # empty dir -- let it fail for now :)
    end
	
	def dir_size dir
	  sum = 0
	  Dir[dir + '/**/*'].each{|f|
	    if File.file? f
		  sum += File.size(f)
		else
		  sum += 1 # empty dir count show up in this number, too :)
		end
	  }
	  sum	  
	end
	
	it 'should do full transfer with 2 clients' do
	  @subject.total_client_size = 3 # 2 clients, plus self
      recipient1 = IncomingCopier.new 'test_dir1', 'dropbox_root_dir', 'longterm_storage1', 0.1, 0.5, 1000, 3 # the ending 3 shouldn't matter here...
	  recipient2 = IncomingCopier.new 'test_dir2', 'dropbox_root_dir', 'longterm_storage2', 0.1, 0.5, 1000, 3
	  recipient1.quiet_mode = true
	  recipient2.quiet_mode = true
	  recipient1.extra_stuff_for_done_file = 'recipient1' # so they'll have distinct touch files
	  recipient2.extra_stuff_for_done_file = 'recipient2'
	  create_a_few_files_in_to_transfer_dir 
      t = Thread.new { @subject.go_single_transfer_out } # starts serving files out...
	  t1 = Thread.new { 2.times { recipient1.go_single_transfer_in } }
	  t2 = Thread.new { 2.times { recipient2.go_single_transfer_in } }
	  # don't need a thread for one of them...
	  2.times { @subject.go_single_transfer_in }
	  t.join
	  t1.join
	  dir_size('longterm_storage').should == 1003
	  dir_size('longterm_storage1').should == 1003
	  dir_size('longterm_storage2').should == 1003	  
	end
	
	context 'should transfer files that are too big for a single go' do
	  it 'should copy the file in, as a piece' do
	    File.write('test_dir/big_file', 'a'*1001)
	    @subject.split_to_chunks.should
	  end
	  
	  it 'should copy the file out, as a piece'
	  it 'should combine the files when done'
	  it 'should mention that its a piece somehow'	  
	
	end

  end

end