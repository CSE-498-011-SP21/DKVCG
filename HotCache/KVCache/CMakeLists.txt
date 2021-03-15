add_library(kvcache INTERFACE)
target_include_directories(kvcache INTERFACE include)
target_link_libraries(kvcache INTERFACE TBB::tbb model kvcg_stuff pthread)

get_target_property(PUBLIC_HEADER_DIR_KVCACHE kvcache INTERFACE_INCLUDE_DIRECTORIES)
file(GLOB_RECURSE PUBLIC_HEADERS_KVCACHE ${PUBLIC_HEADER_DIR_KVCACHE}/*)
set(DOXYGEN_INPUT_DIR "${DOXYGEN_INPUT_DIR} ${PUBLIC_HEADER_DIR_KVCACHE}" PARENT_SCOPE)
set(DOXYGEN_PUBLIC_HEADERS "${DOXYGEN_PUBLIC_HEADERS};${PUBLIC_HEADERS_KVCACHE}" PARENT_SCOPE)

add_executable(kvcache-bench benchmark/KVCache_benchmark.cc)
target_link_libraries(kvcache-bench kvcache)

add_executable(kvcache-tail-latency benchmark/KVCache_tail_latency.cc)
target_link_libraries(kvcache-tail-latency kvcache)