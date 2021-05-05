add_library(canonicalstore INTERFACE)
target_link_libraries(canonicalstore INTERFACE lslab)
target_link_libraries(canonicalstore INTERFACE btree)
target_link_libraries(canonicalstore INTERFACE hotcache)
target_include_directories(canonicalstore INTERFACE include)

get_target_property(PUBLIC_HEADER_DIR_CSTORE canonicalstore INTERFACE_INCLUDE_DIRECTORIES)
file(GLOB_RECURSE PUBLIC_HEADERS_CSTORE ${PUBLIC_HEADER_DIR_CSTORE}/*)

set(DOXYGEN_INPUT_DIR "${DOXYGEN_INPUT_DIR} ${PUBLIC_HEADER_DIR_CSTORE}" PARENT_SCOPE)
set(DOXYGEN_PUBLIC_HEADERS "${DOXYGEN_PUBLIC_HEADERS};${PUBLIC_HEADERS_CSTORE}" PARENT_SCOPE)
