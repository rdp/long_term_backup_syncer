sleep_time = 10
synchro_time = 100 # seconds for a trivial file to propagate
wait_for_all_clients_to_perform_local_dropbox_sync_time = 3*60*60 # 3 hours
dropbox_size = 2.4e9
subject = IncomingCopier.new 'c:\tmp\drop_stuff_in_here', 'dropbox_root_dir', 'longterm_storage_dir', sleep_time, synchro_time, 
wait_for_all_clients_to_perform_local_dropbox_sync_time, dropbox_size, 2
Thread.new { loop { subject.go_single_transfer }}
loop { subject.go_single_transfer_in }
	  