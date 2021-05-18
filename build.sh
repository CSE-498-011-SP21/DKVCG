./vcpkg/bootstrap-vcpkg.sh
./vcpkg/vcpkg install gtest tbb boost-system boost-property-tree

mkdir build
cd build
cmake -DCMAKE_TOOLCHAIN_FILE=../vcpkg/scripts/buildsystems/vcpkg.cmake ..
make -j