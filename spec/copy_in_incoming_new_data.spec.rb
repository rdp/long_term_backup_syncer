require 'rubygems'
require 'sane'
require 'rspec/autorun'
require '../lib/copy_data_to_server.rb'
require 'fileutils'

describe IncomingCopier do
  before do
	FileUtils.rm_rf 'test_dir'
	Dir.mkdir 'test_dir'
	FileUtils.rm_rf 'test_dir.being_transferred'
	FileUtils.rm_rf 'dropbox_root_dir'
	Dir.mkdir 'dropbox_root_dir'
    @subject = IncomingCopier.new 'test_dir', 'dropbox_root_dir', 'longterm_storage', 0.1, 0.5, 0, 1000, 1
    @competitor = "dropbox_root_dir/synchronization/some_other_process.lock"
  end

  it 'should wait for incoming data' do
    passed_gauntlet = false
	stop_time = nil
	start_time = Time.now
    t = Thread.new { @subject.wait_for_any_files_to_appear; stop_time = Time.now}
	sleep 0.5
	FileUtils.touch 'test_dir/a'
	t.join
	(stop_time - start_time).should be > 0.5
  end
  
  it 'should wait for data to stabilize' do
    a = File.open 'test_dir/a', 'w'
	start_time = Time.now
	stop_time = nil
    t = Thread.new { @subject.wait_for_incoming_files_to_stabilize_and_rename_entire_dir; stop_time = Time.now}
    while(Time.now - start_time < 0.5)
      a.puts 'hello'
      a.flush
	  sleep 0.01
    end	  
	a.close
	t.join
	(stop_time - start_time).should be > 0.5
	assert File.directory?('test_dir.being_transferred')
	assert File.exist?('test_dir.being_transferred/a')
  end
  
  def its_lock_file
     "dropbox_root_dir/synchronization/request_#{Process.pid}.lock"
  end
  it 'should create a lock file' do
	assert !File.exist?(its_lock_file)
    @subject.create_lock_file
	assert File.exist?(its_lock_file)
  end
  
  it 'should back off if already locked' do
	FileUtils.touch @competitor
	start_time = Time.now
	stop_time = nil
    t = Thread.new { @subject.wait_if_already_has_lock_files; stop_time = Time.now }
	sleep 0.5
	File.delete @competitor
	t.join
	(stop_time - start_time).should be > 0.5	
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
	stop_time = nil
    t = Thread.new { @subject.obtain_lock; stop_time = Time.now }
	sleep 0.1
	while(Time.now - start_time < 0.75)
  	  FileUtils.touch @competitor
	  sleep 0.1
	  File.delete @competitor
	  sleep 0.1
	end
	t.join
	(stop_time - start_time).should be > 0.75
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
	@subject.split_to_chunks.should == [[a]]
	File.write b, '_'
	@subject.split_to_chunks.should == [[a, b]]
	File.write c, '_'*1000
	@subject.split_to_chunks.should == [[a, b], [c]]
	File.write d, '_'*100
	@subject.split_to_chunks.should == [[a, b], [c], [d]]
	File.write e, '_'*800
	@subject.split_to_chunks.should == [[a, b], [c], [d, e]]
  end

  def create_block_done_files
    FileUtils.touch @subject.track_when_client_done_dir + '/client1_is_done'
  end  
  
  it 'should copy files in' do
    test_dir = File.expand_path '/tmp/test_dir.being_transferred'
	begin
	Dir.mkdir test_dir
    subject = IncomingCopier.new '/tmp/test_dir', 'dropbox_root_dir', 'longterm', 0.1, 0.5, 0, 1000, 2
	FileUtils.mkdir_p test_dir + '/subdir'
    File.write test_dir + '/a', '_'
    File.write test_dir + '/subdir/b', '_'
	subject.create_lock_file
	t = Thread.new {subject.copy_chunk_in [test_dir + '/a', test_dir + '/subdir/b']}
	sleep 0.2
	create_block_done_files	
	t.join
	assert File.exist? "dropbox_root_dir/temp_transfer/a"
	assert File.exist? "dropbox_root_dir/temp_transfer/subdir/b"
	ensure
    FileUtils.rm_rf test_dir
	end	
  end
  
  def create_a_few_files_in_dropbox
    File.write 'test_dir/a', '_'
	Dir.mkdir 'test_dir/subdir'
	File.write 'test_dir/subdir/b', '_' * 1000  
  end
  
  it 'should do a complete multi-chunk transfer' do
    create_a_few_files_in_dropbox
	t = Thread.new { @subject.go_single_transfer_out }	
	while !@subject.previous_you_can_go_for_it_size_file
	  sleep 0.1
	end
	2.times {
	  while !File.exist?(@subject.previous_you_can_go_for_it_size_file) # takes quite awhile [LODO check...]
	    sleep 0.1
	  end
	  create_block_done_files
	  sleep 0.2 # let it delete them
	}
	t.join
	assert !File.exist?(@subject.track_when_client_done_dir + '/a') # old client done file
	
	Dir['dropbox_root_dir/temp_transfer/*'].length.should == 0 # cleaned up drop box
	assert !File.exist?(its_lock_file)
	assert !File.exist?(@subject.previous_you_can_go_for_it_size_file)
	assert !File.exist?('test_dir/a')
	assert !File.exist?('test_dir.being_transferred/a')
	assert !File.exist?('test_dir/subdir')
	assert !File.exist?('test_dir.being_transferred/subdir')
  end
  
  it 'should wait for clients to finish downloading it' do
    start_time = Time.now
	stop_time = nil
    @subject = IncomingCopier.new 'test_dir', 'dropbox_root_dir', 'longterm_storage', 0.1, 0.5, 0, 1000, 2
    t = time_in_other_thread { @subject.wait_for_all_clients_to_copy_files_out}
    FileUtils.touch @subject.track_when_client_done_dir + '/a'
	sleep 0.5
    FileUtils.touch @subject.track_when_client_done_dir + '/b'
	t.join
	@thread_took.should be < 1
	@thread_took.should be > 0.5
	assert !File.exist?(@subject.track_when_client_done_dir + '/a')
	assert !File.exist?(@subject.track_when_client_done_dir + '/b')
  end
  
  it 'should touch the you can go for it file' do
    @subject.create_lock_file
    @subject.touch_the_you_can_go_for_it_file(777)
	assert File.exist? @subject.previous_you_can_go_for_it_size_file
	proc { @subject.touch_the_you_can_go_for_it_file(787) }.should raise_exception /should be locked/
	proc { @subject.copy_files_in_by_chunks }.should raise_exception /no files/
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
	
    it 'should copy the files over' do
 	  File.write "dropbox_root_dir/temp_transfer/a", '_'
	  FileUtils.mkdir "dropbox_root_dir/temp_transfer/subdir"
 	  File.write "dropbox_root_dir/temp_transfer/subdir/b", '_'
	  @subject.copy_current_files_to_local_permanent_storage
	  assert File.exist?('longterm_storage/a')  
	  assert File.exist?('longterm_storage/subdir/b')
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
	  create_a_few_files_in_dropbox
      t = Thread.new { @subject.go_single_transfer_out }
	  @subject.go_single_transfer_in
	  @subject.go_single_transfer_in
	  t.join
	  assert File.exist?(@subject.longterm_storage_dir + '/a')
	  assert File.exist?(@subject.longterm_storage_dir + '/subdir/b')
	end

  end

end