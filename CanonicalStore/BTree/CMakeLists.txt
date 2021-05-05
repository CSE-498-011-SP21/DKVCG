enable_testing()

add_library(btree INTERFACE)
target_include_directories(btree INTERFACE src)
add_subdirectory(test)
add_subdirectory(unittests)

set(DOXYGEN_INPUT_DIR "${DOXYGEN_INPUT_DIR} ${PUBLIC_HEADER_DIR_CSTORE}" PARENT_SCOPE)
set(DOXYGEN_PUBLIC_HEADERS "${DOXYGEN_PUBLIC_HEADERS};${PUBLIC_HEADERS_CSTORE}" PARENT_SCOPE)

