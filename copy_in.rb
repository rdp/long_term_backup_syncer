require 'shared'
=begin

0. notice incoming files

1. create lock file, wait
2. copy in "a chunk"
  split files for now
2.5 create "1 client has it"
3. remove lock file
4. wait till "x" clients have each picked it up.
5. delete it
=end

