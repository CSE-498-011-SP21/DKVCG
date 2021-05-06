#!/bin/bash
kvcgExe=../cmake-build-relwithdebinfo/benchmark/kvcg
soFile=../cmake-build-relwithdebinfo/benchmark/libzipfianWorkloadNoDelete.so


keysize=8
ratio=95
#theta=0.5
# number of batches to run
batches=100
# operations per batch
n=10000

# The BTree can only function with one GPU, one CUDA stream, and <4B keys and values.
# It's easy to make keysize less than 4 bytes, but it's harder with values because those are actual pointers to data.
#
streams=1

serverJson="{\"cpu_threads\":  12,
  \"threads\" : 2,
  \"streams\" : $streams,
  \"gpus\" : 1,
  \"train\" : false,
  \"size\" : 1000000,
  \"cache\" : true
}"
echo $serverJson > server.json

thetas=("0.0" "0.1" "0.2" "0.3" "0.4" "0.5" "0.6" "0.7" "0.8" "0.9")

for theta in "${thetas[@]}"; do
  workloadJson="{
        \"theta\" : $theta,
        \"range\" : 1000000000,
        \"n\" : $n,
        \"ops\" : $batches,
        \"keysize\" : $keysize,
        \"ratio\" : $ratio
      }"

  echo $workloadJson > workload.json

  trials=2
  for ((i=0; i<trials; i++))
  do
    echo "TRIAL: $i"
    echo "theta: $theta"
    $kvcgExe -l $soFile -f ./server.json -w ./workload.json > /dev/null
    echo "Sleeping for 5s"
    sleep 5s
  done

done

rm server.json
rm workload.json
