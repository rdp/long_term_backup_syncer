require 'rubygems'
require 'sane'
require 'rspec/autorun'
require '../copy_in_incoming_new_data.rb'
require 'fileutils'

describe IncomingCopier do
  before do
	FileUtils.rm_rf 'test_dir'
	Dir.mkdir 'test_dir'
	FileUtils.rm_rf 'dropbox_root_dir'
	Dir.mkdir 'dropbox_root_dir'
    @subject = IncomingCopier.new 'test_dir', 'dropbox_root_dir', 0.1, 0.5, 1000
    @competitor = "dropbox_root_dir/synchronization/some_other_process.lock"
  end

  it 'should wait for incoming data' do
    passed_gauntlet = false
	stop_time = nil
	start_time = Time.now
    t = Thread.new { @subject.wait_for_files_to_appear; stop_time = Time.now}
	sleep 0.5
	FileUtils.touch 'test_dir/a'
	t.join
	(stop_time - start_time).should be > 0.5
  end
  
  it 'should wait for data to stabilize' do
    a = File.open 'test_dir/a', 'w'
	start_time = Time.now
	stop_time = nil
    t = Thread.new { @subject.wait_for_incoming_files_to_stabilize; stop_time = Time.now}
    while(Time.now - start_time < 0.5)
      a.puts 'hello'
      a.flush
	  sleep 0.01
    end	  
	a.close
	t.join
	(stop_time - start_time).should be > 0.5
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
	@subject.sleep_time = 0
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
  def dbg
  require 'ruby-debug'
  debugger
  end
  it 'should split incoming data to transferrable chunks' do
    proc { @subject.split_to_chunks}.should raise_exception(/no files/)
	test_dir = File.expand_path 'test_dir'
	a = test_dir + '/a'
	b = test_dir + '/b'
	c = test_dir + '/c'
	d = test_dir + '/d'
	e = test_dir + '/e'
    File.write 'test_dir/a', '_'
	@subject.split_to_chunks.should == [[a]]
	File.write 'test_dir/b', '_'
	@subject.split_to_chunks.should == [[a, b]]
	File.write 'test_dir/c', '_'*1000
	@subject.split_to_chunks.should == [[a, b], [c]]
	File.write 'test_dir/d', '_'*100
	@subject.split_to_chunks.should == [[a, b], [c], [d]]
	File.write 'test_dir/e', '_'*800
	@subject.split_to_chunks.should == [[a, b], [c], [d, e]]
  end
  
  it 'should copy files in' do
    subject = IncomingCopier.new '/tmp/test_dir', 'dropbox_root_dir', 0.1, 0.5, 1000
	Dir.mkdir '/tmp' unless File.directory '/tmp'
	Dir.mkdir '/tmp/test_dir'
    File.write '/tmp/test_dir/a', '_'
	Dir.mkdir '/tmp/test_dir/subdir'
    File.write '/tmp/test_dir/subdir/b', '_'
	subject.copy_files_in_by_chunks
	assert File.exist? "dropbox_root_dir/temp_transfer/a"
	assert File.exist? "dropbox_root_dir/temp_transfer/subdir/b"
  end

end