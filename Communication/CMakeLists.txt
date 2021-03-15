add_library(communication INTERFACE)
target_include_directories(communication INTERFACE include)
target_link_libraries(communication INTERFACE kvcg_stuff)
#target_link_libraries(communication INTERFACE fabricBased)

get_target_property(PUBLIC_HEADER_DIR_COMM communication INTERFACE_INCLUDE_DIRECTORIES)
file(GLOB_RECURSE PUBLIC_HEADERS_COMM ${PUBLIC_HEADER_DIR_COMM}/*)

set(DOXYGEN_INPUT_DIR "${DOXYGEN_INPUT_DIR} ${PUBLIC_HEADER_DIR_COMM}" PARENT_SCOPE)
set(DOXYGEN_PUBLIC_HEADERS "${DOXYGEN_PUBLIC_HEADERS};${PUBLIC_HEADERS_COMM}" PARENT_SCOPE)
