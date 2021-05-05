add_executable(test_map test_map.cu)
target_link_libraries(test_map PRIVATE btree)

add_executable(test_search test_map_search.cu)
target_link_libraries(test_search PRIVATE btree)

add_test(BTREE_buildMap_test test_map)
add_test(BTREE_buildAndSearchMap_test test_search)