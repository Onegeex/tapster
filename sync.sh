#!/bin/bash
# Copy the workspace into the gno examples tree so gno test resolves stdlib packages offline.
set -e
EX=/home/claude/gno/examples/gno.land
rm -rf $EX/p/tapsterns $EX/r/tapsterns
mkdir -p $EX/p/tapsterns $EX/r/tapsterns
cp -r /home/claude/tapster/gno/p/tapmath $EX/p/tapsterns/tapmath
cp -r /home/claude/tapster/gno/r/tapster $EX/r/tapsterns/tapster
cp -r /home/claude/tapster/gno/r/tab $EX/r/tapsterns/tab
