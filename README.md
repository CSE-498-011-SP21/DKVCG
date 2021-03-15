# KVCG

KVCG is a cooperative GPU-CPU key value store.

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
