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
cmake -DCMAKE_TOOCHAIN_FILE=../vcpkg/scripts/buildsystems/vcpkg.cmake ..
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

## Running without a GPU

Set gpus in the configuration file to 0.