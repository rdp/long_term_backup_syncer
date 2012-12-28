require File.dirname(__FILE__) + "/copy_data_to_server.rb"

class Numeric
  def gig
    self * 1e9
  end
end

sleep_time = 10
synchro_time = 100 # seconds for a trivial file to propagate
dropbox_size = 2.4.gig
total_client_size=2

$subject = IncomingCopier.new 'c:\tmp\drop_stuff_in_here', 'dropbox_root_dir', 'longterm_storage_dir', sleep_time, synchro_time, 
  dropbox_size, total_client_size
  
puts 'remember to pre-zip them (and videos too) for now, if desired!'

Thread.new { loop { $subject.go_single_transfer_out }}
loop { $subject.go_single_transfer_in }