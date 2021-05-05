project(CanonicalStore)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CUDA_STANDARD 17)
set(CMAKE_CUDA_STANDARD_REQUIRED ON)
set(CMAKE_CUDA_ARCHITECTURES OFF)

message("BUILD TYPE: ${CMAKE_BUILD_TYPE}")

if (CMAKE_BUILD_TYPE STREQUAL "Debug")
    string(APPEND CMAKE_CUDA_FLAGS " -G -pg")
    message("CUDA FLAGS: ${CMAKE_CUDA_FLAGS}")
endif (CMAKE_BUILD_TYPE STREQUAL "Debug")

if (CMAKE_BUILD_TYPE STREQUAL "RelWithDebInfo")
    string(APPEND CMAKE_CUDA_FLAGS " -lineinfo -pg")
    message("CUDA FLAGS: ${CMAKE_CUDA_FLAGS}")
endif (CMAKE_BUILD_TYPE STREQUAL "RelWithDebInfo")

if (NOT DEFINED CUDA_ARCH)
    set(CUDA_ARCH "60" "61" "70" "75")
    message("WARNING CUDA_ARCH IS GENERATING DEFAULT ${CUDA_ARCH}")
endif (NOT DEFINED CUDA_ARCH)

string(APPEND CMAKE_CUDA_FLAGS " --expt-extended-lambda -Xptxas=-v")

foreach (ARCH_ELM ${CUDA_ARCH})
    message("${ARCH_ELM}")
    string(APPEND CMAKE_CUDA_FLAGS " -gencode arch=compute_${ARCH_ELM},code=sm_${ARCH_ELM}")
endforeach (ARCH_ELM)

string(APPEND CMAKE_CUDA_FLAGS " -Wreorder")

message(${CMAKE_CUDA_FLAGS})

add_compile_options("$<$<CONFIG:DEBUG>:-DDEBUG>")

add_subdirectory(Allocator)
add_subdirectory(LSlab)
add_subdirectory(CanonicalStoreInterface)
add_subdirectory(BTree)

set(DOXYGEN_INPUT_DIR "${DOXYGEN_INPUT_DIR}" PARENT_SCOPE)
set(DOXYGEN_PUBLIC_HEADERS "${DOXYGEN_PUBLIC_HEADERS}" PARENT_SCOPE)
