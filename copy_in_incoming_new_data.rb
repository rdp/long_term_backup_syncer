require 'shared'
=begin

0. notice incoming files
0.5 sleep a bit to make sure there aren't more coming...
1. create lock file, wait
2. copy in "a chunk"
  split files for now
2.5 create "1 client has it"
3. remove lock file
4. wait till "x" clients have each picked it up.
5. delete it
=end

def files_incoming
  Dir[@local_drop_here_to_save_dir + '/**/*']
end

incoming_length = 0
while incoming_length == 0
  incoming_length = files_incoming.length
end
old_incoming_length = -1

puts 'waiting to see when they\'re done'
while(incoming_length != old_incoming_length) 
 sleep 10
 old_incoming_length = files_incoming.length
end