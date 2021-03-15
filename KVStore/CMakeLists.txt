set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CUDA_STANDARD 17)

add_library(kvstore INTERFACE)
target_include_directories(kvstore INTERFACE include)
target_link_libraries(kvstore INTERFACE pthread)
target_link_libraries(kvstore INTERFACE lslab)
target_link_libraries(kvstore INTERFACE kvcache)
target_link_libraries(kvstore INTERFACE tbb)
target_link_libraries(kvstore INTERFACE kvcg_stuff)
target_link_libraries(kvstore INTERFACE commonInterfacesCUDA)
target_link_libraries(kvstore INTERFACE canonicalstore)

# used for Doxygen
get_target_property(PUBLIC_HEADER_DIR_KVSTORE kvstore INTERFACE_INCLUDE_DIRECTORIES)
file(GLOB_RECURSE PUBLIC_HEADERS_KVSTORE ${PUBLIC_HEADER_DIR_KVSTORE}/*)
set(DOXYGEN_INPUT_DIR "${DOXYGEN_INPUT_DIR} ${PUBLIC_HEADER_DIR_KVSTORE}" PARENT_SCOPE)
set(DOXYGEN_PUBLIC_HEADERS "${DOXYGEN_PUBLIC_HEADERS};${PUBLIC_HEADERS_KVSTORE}" PARENT_SCOPE)

add_executable(KVStoreClientTest test/KVStoreClientTest.cu)
target_link_libraries(KVStoreClientTest GTest::gmock GTest::gtest GTest::gmock_main GTest::gtest_main kvstore)
add_test(KVStoreClientTest KVStoreClientTest)

add_executable(KVStoreCtxTest test/KVStoreCtxTest.cu)
target_link_libraries(KVStoreCtxTest GTest::gmock GTest::gtest GTest::gmock_main GTest::gtest_main kvstore)
add_test(KVStoreCtxTest KVStoreCtxTest)

add_executable(KVStoreInternalClientTest test/KVStoreInternalClientTest.cu)
target_link_libraries(KVStoreInternalClientTest GTest::gmock GTest::gtest GTest::gmock_main GTest::gtest_main kvstore)
add_test(KVStoreInternalClientTest KVStoreInternalClientTest)

add_executable(KVStoreTest test/KVStoreTest.cu)
target_link_libraries(KVStoreTest GTest::gmock GTest::gtest GTest::gmock_main GTest::gtest_main kvstore)
add_test(KVStoreTest KVStoreTest)

add_executable(SimpleFutureTest test/SimpleFutureTest.cu)
target_link_libraries(SimpleFutureTest GTest::gmock GTest::gtest GTest::gmock_main GTest::gtest_main kvstore)
add_test(SimpleFutureTest SimpleFutureTest)

add_executable(model_service_rate benchmark/model_service_rate.cu)
