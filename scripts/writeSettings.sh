#!/bin/bash

keysize=8
ratio=95
theta=0.5
# number of batches to run
batches=100
# operations per batch
n=10000

# The BTree can only function with one GPU, one CUDA stream, and <4B keys and values.
# It's easy to make keysize less than 4 bytes, but it's harder with values because those are actual pointers to data.
#
streams=1


workloadJson="{
        \"theta\" : $theta,
        \"range\" : 1000000000,
        \"n\" : $n,
        \"ops\" : $batches,
        \"keysize\" : $keysize,
        \"ratio\" : $ratio
      }"

echo $workloadJson > workload.json

serverJson="{\"cpu_threads\":  12,
  \"threads\" : 2,
  \"streams\" : $streams,
  \"gpus\" : 1,
  \"train\" : false,
  \"size\" : 1000000,
  \"cache\" : true
}"
echo $serverJson > server.json