#!/bin/bash
cd /tmp/cp-wt/spikes/docs/spikes/S1
PROMPT=v2 python3 harness.py pi off > run-pi-off-v2.log 2>&1
TAG=rep2 python3 harness.py pi off > run-pi-off-rep2.log 2>&1
python3 harness.py pi medium > run-pi-medium.log 2>&1
echo done
