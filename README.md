# DKVCG

DKVCG is a cooperative GPU-CPU distributed key value store.

## Dependencies

- TBB
- Boost
- Google Test
- CUDA 11.2
- Support for C++17

## Building

This will build the code and run sanity checks.

```shell
git submodule update --init --recursive
./vcpkg/bootstrap-vcpkg.sh
./vcpkg/vcpkg install gtest tbb boost-system boost-property-tree
mkdir build
cd build
cmake -DCMAKE_TOOLCHAIN_FILE=../vcpkg/scripts/buildsystems/vcpkg.cmake ..
make -j
ctest
```

You can also build with the dockerfile.

## Docker

Create a rsa public key and private key named docker_rsa and docker_rsa.pub in this directory and 
register it with Github.

Run buildDocker.sh to build the docker image.

Run runDocker.sh to run the docker image. Note that it maps the host directory into the container, 
so modifications will persist after exiting the container.

Go to /dkvcg once in the container and run build.sh to build the project.

## Configuration File

Example configuration:

```json
{
  "threads": 4,
  "cpu_threads": 12,
  "gpus": 1,
  "streams": 10,
  "modelFile": "",
  "train": false,
  "size": 1000000,
  "batchSize": 512,
  "cache": true,
  "address" : "127.0.0.1",
  "port" : 8080
}
```

- threads corresponds to number of threads to handle client requests
- cpu threads corresponds to number of threads in the pool running the hot cache
- gpus corresponds to the number of gpus
- streams corresponds to the number of streams to handle GPU requests
- modelFile corresponds to the model file
- train corresponds to whether training should occur for requests
- size corresponds to the index size
- batch size corresponds to the expected batch size
- cache corresponds to whether the hot cache should be used

## Running without a GPU

Set gpus in the configuration file to 0.

## Running on Cloudlab

Make sure to use the experiment network as the underlying network, otherwise you will likely get 
your account kicked off of Cloudlab.
