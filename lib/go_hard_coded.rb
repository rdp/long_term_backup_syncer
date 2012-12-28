class Numeric
  def gig
    self * 1e9
  end
end

sleep_time = 10
synchro_time = 100 # seconds for a trivial file to propagate
dropbox_size = 2.4.gig
total_client_size=2
# THESE AREN'T ACTUALLY LIVE DATA VALUES YET

$subject = IncomingCopier.new 'c:\tmp\drop_stuff_in_here', 'dropbox_root_dir', 'longterm_storage_dir', sleep_time, synchro_time, 
  dropbox_size, total_client_size