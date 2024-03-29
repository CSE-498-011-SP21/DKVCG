cmake_minimum_required(VERSION 3.18)

set(CMAKE_TOOLCHAIN_FILE ./vcpkg/scripts/buildsystems/vcpkg.cmake)

project(DKVCG LANGUAGES CXX CUDA)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CUDA_STANDARD 17)
set(CMAKE_CUDA_STANDARD_REQUIRED ON)
set(CMAKE_CUDA_ARCHITECTURES OFF)
message("USING ${CMAKE_TOOLCHAIN_FILE}")

find_package(Doxygen)
find_package(Boost REQUIRED)
find_package(TBB REQUIRED)
find_package(GTest CONFIG REQUIRED)

include(FetchContent)

FetchContent_Declare(
        NetworkLayer
        GIT_REPOSITORY git@github.com:CSE-498-011-SP21/network-layer.git
        GIT_TAG main
)

FetchContent_MakeAvailable(NetworkLayer)

FetchContent_Declare(
        FaultTolerance
        GIT_REPOSITORY git@github.com:CSE-498-011-SP21/fault-tolerance.git
        GIT_TAG main
)

FetchContent_MakeAvailable(FaultTolerance)

enable_testing()

add_subdirectory(commonInterfaces)

add_subdirectory(Model)

add_subdirectory(HotCache)

add_subdirectory(Communication)

add_subdirectory(CanonicalStore)

add_subdirectory(KVStore)

add_subdirectory(benchmark)

add_subdirectory(docs)

add_executable(dkvcg service/server.cu)
target_link_libraries(dkvcg PUBLIC lslab)
target_link_libraries(dkvcg PUBLIC pthread)
target_link_libraries(dkvcg PUBLIC kvstore)
target_link_libraries(dkvcg PUBLIC tbbmalloc_proxy)
target_link_libraries(dkvcg PUBLIC Boost::boost)
target_link_libraries(dkvcg PUBLIC threadpool)
target_link_libraries(dkvcg PUBLIC faulttolerance)
# Enable loopback support for testing
target_compile_definitions(faulttolerance PUBLIC LOOPBACK)

add_executable(dkvcg_client service/client.cu)
target_link_libraries(dkvcg_client PUBLIC lslab)
target_link_libraries(dkvcg_client PUBLIC pthread)
target_link_libraries(dkvcg_client PUBLIC kvstore)
target_link_libraries(dkvcg_client PUBLIC tbbmalloc_proxy)
target_link_libraries(dkvcg_client PUBLIC Boost::boost)
target_link_libraries(dkvcg_client PUBLIC faulttolerance)


set(KVGPU_TARGETLIST ${KVGPU_TARGETLIST} kvstore rand)

install(TARGETS ${KVGPU_TARGETLIST}
        LIBRARY DESTINATION lib
        ARCHIVE DESTINATION lib
        RUNTIME DESTINATION bin
        INCLUDES DESTINATION include
        )

set(CPACK_PACKAGE_VENDOR "dePaul Miller et. al.")
SET(CPACK_GENERATOR "DEB")
SET(CPACK_DEBIAN_PACKAGE_MAINTAINER "dePaul Miller")
set(CPACK_SOURCE_GENERATOR "TGZ;ZIP")
set(CPACK_SOURCE_IGNORE_FILES
        /.git
        /dist
        /.*build.*
        /\\\\.DS_Store
        )
include(CPack)
