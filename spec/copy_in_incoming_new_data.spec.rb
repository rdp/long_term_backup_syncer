require 'rubygems'
require 'rspec/autorun'
require '../copy_in_incoming_new_data.rb'
require 'fileutils'

describe IncomingCopier do
  before do
    @subject = IncomingCopier.new 'test_dir', 0.2
	FileUtils.rm_rf 'test_dir'
	Dir.mkdir 'test_dir'
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
	10.times {
	  a.puts 'hello'; a.flush
	  sleep 0.1
	}
	t.join
	(stop_time - start_time).should be > 1.0
  end

end