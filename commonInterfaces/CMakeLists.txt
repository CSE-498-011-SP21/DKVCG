add_library(commonInterfacesCUDA INTERFACE)
target_include_directories(commonInterfacesCUDA INTERFACE includeCUDA)
target_link_libraries(commonInterfacesCUDA INTERFACE kvcg_stuff)
target_link_libraries(commonInterfacesCUDA INTERFACE communication)

get_target_property(PUBLIC_HEADER_DIR_INTCUDA commonInterfacesCUDA INTERFACE_INCLUDE_DIRECTORIES)
file(GLOB_RECURSE PUBLIC_HEADERS_INTCUDA ${PUBLIC_HEADER_DIR_INTCUDA}/*)
set(DOXYGEN_INPUT_DIR "${DOXYGEN_INPUT_DIR} ${PUBLIC_HEADER_DIR_INTCUDA}" PARENT_SCOPE)
set(DOXYGEN_PUBLIC_HEADERS "${DOXYGEN_PUBLIC_HEADERS};${PUBLIC_HEADERS_INTCUDA}" PARENT_SCOPE)
