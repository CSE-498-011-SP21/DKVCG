add_library(hotcache INTERFACE)
target_include_directories(hotcache INTERFACE include)
target_link_libraries(hotcache INTERFACE kvcache)

get_target_property(PUBLIC_HEADER_DIR_HOTCACHE hotcache INTERFACE_INCLUDE_DIRECTORIES)
file(GLOB_RECURSE PUBLIC_HEADERS_HOTCACHE ${PUBLIC_HEADER_DIR_HOTCACHE}/*)
set(DOXYGEN_INPUT_DIR "${DOXYGEN_INPUT_DIR} ${PUBLIC_HEADER_DIR_HOTCACHE}" PARENT_SCOPE)
set(DOXYGEN_PUBLIC_HEADERS "${DOXYGEN_PUBLIC_HEADERS};${PUBLIC_HEADERS_HOTCACHE}" PARENT_SCOPE)
