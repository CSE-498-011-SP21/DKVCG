/*Copyright(c) 2020, The Regents of the University of California, Davis.            */
/*                                                                                  */
/*                                                                                  */
/*Redistribution and use in source and binary forms, with or without modification,  */
/*are permitted provided that the following conditions are met :                    */
/*                                                                                  */
/*1. Redistributions of source code must retain the above copyright notice, this    */
/*list of conditions and the following disclaimer.                                  */
/*2. Redistributions in binary form must reproduce the above copyright notice,      */
/*this list of conditions and the following disclaimer in the documentation         */
/*and / or other materials provided with the distribution.                          */
/*                                                                                  */
/*THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND   */
/*ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED     */
/*WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.*/
/*IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT,  */
/*INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES(INCLUDING, BUT */
/*NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR*/
/*PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, */
/*WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT(INCLUDING NEGLIGENCE OR OTHERWISE) */
/*ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE        */
/*POSSIBILITY OF SUCH DAMAGE.                                                       */
/************************************************************************************/
/************************************************************************************/

#include <cstdio>
#include <cstdint>
#include <vector>
#include "../allocator/bool_allocator.cuh"
#include "kernels/map_kernels.cuh"
#include "SecondaryIndex.cuh"

#ifndef GPU_B_TREE_CUH
#define GPU_B_TREE_CUH

namespace GpuBTree {
    template<typename KeyT,
            typename ValueT,
            typename SizeT = KeyT,
            typename AllocatorT = BoolAllocator>
    class GpuBTreeMap {
    private:
        static constexpr uint32_t EMPTY_KEY = 0xFFFFFFFF;
        // FIXME: Global define DELETED_KEY is in Operations.cuh, annoying. Neither of them are ever used.
        static constexpr uint32_t BTREE_DELETED_KEY = 0xFFFFFFFF;
        static constexpr uint32_t BLOCKSIZE_BUILD_ = 128;
        static constexpr uint32_t BLOCKSIZE_SEARCH_ = 1024;

        SizeT _num_keys;
        int _device_id;
        uint32_t *_d_root;
        AllocatorT _mem_allocator;

        cudaError_t initBTree(uint32_t *&root, cudaStream_t stream_id = 0) {
            kernels::init_btree<<<1, 32, 0, stream_id>>>(root, _mem_allocator);
            return cudaDeviceSynchronize();
        }

        cudaError_t insertKeys(uint32_t *&root,
                               KeyT *&d_keys,
                               ValueT *&d_values,
                               SizeT &count,
                               cudaStream_t stream_id = 0) {
            const uint32_t num_blocks = (count + BLOCKSIZE_BUILD_ - 1) / BLOCKSIZE_BUILD_;
            const uint32_t shared_bytes = 0;
            kernels::insert_keys<<<num_blocks, BLOCKSIZE_BUILD_, shared_bytes, stream_id>>>(
                    root, d_keys, d_values, count, _mem_allocator);

            return cudaSuccess;
        }

        cudaError_t searchKeys(uint32_t *&root,
                               KeyT *&d_queries,
                               ValueT *&d_results,
                               SizeT &count,
                               cudaStream_t stream_id = 0) {
            const uint32_t num_blocks = (count + BLOCKSIZE_SEARCH_ - 1) / BLOCKSIZE_SEARCH_;
            const uint32_t shared_bytes = 0;
            kernels::search_b_tree<<<num_blocks, BLOCKSIZE_SEARCH_, shared_bytes, stream_id>>>(
                    root, d_queries, d_results, count, _mem_allocator);

            return cudaSuccess;
        }

        cudaError_t compactTree(uint32_t *&root,
                                KeyT *&d_tree,
                                SizeT *&d_num_nodes,
                                cudaStream_t stream_id = 0) {
            const uint32_t num_blocks = 1;
            const uint32_t block_size = 32;
            const uint32_t shared_bytes = 0;
            kernels::compact_tree<<<num_blocks, block_size, shared_bytes, stream_id>>>(
                    root, d_tree, d_num_nodes, _mem_allocator);

            return cudaSuccess;
        }

        cudaError_t deleteKeys(uint32_t *&root,
                               KeyT *&d_queries,
                               SizeT &count,
                               cudaStream_t stream_id = 0) {
            const uint32_t num_blocks = (count + BLOCKSIZE_SEARCH_ - 1) / BLOCKSIZE_SEARCH_;
            const uint32_t shared_bytes = 0;
            kernels::delete_b_tree<<<num_blocks, BLOCKSIZE_SEARCH_, shared_bytes, stream_id>>>(
                    root, d_queries, count, _mem_allocator);

            return cudaSuccess;
        }

        cudaError_t concurrentOperations(uint32_t *&root,
                                         KeyT *&d_keys,
                                         ValueT *&d_values,
                                         OperationT *d_ops,
                                         SizeT &count,
                                         cudaStream_t stream_id = 0) {
            const uint32_t num_blocks = (count + BLOCKSIZE_SEARCH_ - 1) / BLOCKSIZE_SEARCH_;
            const uint32_t shared_bytes = 0;
            kernels::
            concurrent_ops_b_tree<<<num_blocks, BLOCKSIZE_SEARCH_, shared_bytes, stream_id>>>(
                    root, d_keys, d_values, d_ops, count, _mem_allocator);

            return cudaSuccess;
        }

        bool _handle_memory;

    public:
        GpuBTreeMap(AllocatorT *mem_allocator = nullptr, int device_id = 0) {
            if (mem_allocator) {
                _mem_allocator = *mem_allocator;
                _handle_memory = false;
            } else {
                BoolAllocator allocator;
                allocator.init();
                _mem_allocator = allocator;
                _mem_allocator.init();
                CHECK_ERROR(memoryUtil::deviceAlloc(_d_root, 1));
                _handle_memory = true;
            }
            _device_id = device_id;
            CHECK_ERROR(cudaSetDevice(_device_id));
            initBTree(_d_root);
        }

        cudaError_t init(AllocatorT mem_allocator, uint32_t *root_, int deviceId = 0) {
            _device_id = deviceId;
            _mem_allocator = mem_allocator;
            _d_root = root_;  // assumes that the root already contains a one
            return cudaSuccess;
        }

        ~GpuBTreeMap() {}

        void free() {
            if (_handle_memory) {
                CHECK_ERROR(cudaDeviceSynchronize());
                _mem_allocator.free();
            }
        }

        __host__ __device__ AllocatorT *getAllocator() { return &_mem_allocator; }

        __host__ __device__ uint32_t *getRoot() { return _d_root; }

        cudaError_t insertKeys(KeyT *keys,
                               ValueT *values,
                               SizeT count,
                               SourceT source = SourceT::DEVICE) {
            KeyT *d_keys;
            ValueT *d_values;
            if (source == SourceT::HOST) {
                CHECK_ERROR(memoryUtil::deviceAlloc(d_keys, count));
                CHECK_ERROR(memoryUtil::deviceAlloc(d_values, count));
                CHECK_ERROR(memoryUtil::cpyToDevice(keys, d_keys, count));
                CHECK_ERROR(memoryUtil::cpyToDevice(values, d_values, count));
            } else {
                d_keys = keys;
                d_values = values;
            }

            CHECK_ERROR(insertKeys(_d_root, d_keys, d_values, count));

            if (source == SourceT::HOST) {
                CHECK_ERROR(memoryUtil::deviceFree(d_keys));
                CHECK_ERROR(memoryUtil::deviceFree(d_values));
            }

            return cudaSuccess;
        }

        cudaError_t searchKeys(KeyT *queries,
                               ValueT *results,
                               SizeT count,
                               SourceT source = SourceT::DEVICE) {
            KeyT *d_queries;
            ValueT *d_results;
            if (source == SourceT::HOST) {
                CHECK_ERROR(memoryUtil::deviceAlloc(d_queries, count));
                CHECK_ERROR(memoryUtil::deviceAlloc(d_results, count));

                CHECK_ERROR(memoryUtil::cpyToDevice(queries, d_queries, count));
            } else {
                d_queries = queries;
                d_results = results;
            }

            CHECK_ERROR(searchKeys(_d_root, d_queries, d_results, count));

            if (source == SourceT::HOST) {
                CHECK_ERROR(memoryUtil::cpyToHost(d_results, results, count));
                CHECK_ERROR(memoryUtil::deviceFree(d_queries));
                CHECK_ERROR(memoryUtil::deviceFree(d_results));
            }

            return cudaSuccess;
        }

        cudaError_t compactTree(KeyT *&btree,
                                SizeT max_nodes,
                                SizeT &num_nodes,
                                SourceT source = SourceT::DEVICE) {
            KeyT *d_tree;
            KeyT *d_num_nodes;
            if (source == SourceT::HOST) {
                CHECK_ERROR(memoryUtil::deviceAlloc(d_tree, max_nodes * NODE_WIDTH));
                CHECK_ERROR(memoryUtil::deviceAlloc(d_num_nodes, 1));
            } else {
                d_tree = btree;
                d_num_nodes = &num_nodes;
            }

            CHECK_ERROR(compactTree(_d_root, d_tree, d_num_nodes));

            if (source == SourceT::HOST) {
                CHECK_ERROR(memoryUtil::cpyToHost(d_num_nodes, &num_nodes, 1));
                CHECK_ERROR(memoryUtil::deviceFree(d_num_nodes));

                CHECK_ERROR(memoryUtil::cpyToHost(d_tree, btree, num_nodes * NODE_WIDTH));
                CHECK_ERROR(memoryUtil::deviceFree(d_tree));
            }

            return cudaSuccess;
        }

        cudaError_t deleteKeys(KeyT *queries, SizeT count, SourceT source = SourceT::DEVICE) {
            KeyT *d_queries;
            if (source == SourceT::HOST) {
                CHECK_ERROR(memoryUtil::deviceAlloc(d_queries, count));
                CHECK_ERROR(memoryUtil::cpyToDevice(queries, d_queries, count));
            } else {
                d_queries = queries;
            }

            CHECK_ERROR(deleteKeys(_d_root, d_queries, count));

            if (source == SourceT::HOST) {
                CHECK_ERROR(memoryUtil::deviceFree(d_queries));
            }

            return cudaSuccess;
        }

        cudaError_t concurrentOperations(KeyT *keys,
                                         ValueT *values,
                                         OperationT *ops,
                                         SizeT count,
                                         SourceT source = SourceT::DEVICE) {
            KeyT *d_keys;
            ValueT *d_values;
            OperationT *d_ops;
            if (source == SourceT::HOST) {
                CHECK_ERROR(memoryUtil::deviceAlloc(d_keys, count));
                CHECK_ERROR(memoryUtil::deviceAlloc(d_values, count));
                CHECK_ERROR(memoryUtil::deviceAlloc(d_ops, count));
                CHECK_ERROR(memoryUtil::cpyToDevice(keys, d_keys, count));
                CHECK_ERROR(memoryUtil::cpyToDevice(values, d_values, count));
                CHECK_ERROR(memoryUtil::cpyToDevice(ops, d_ops, count));
            } else {
                d_keys = keys;
                d_values = values;
            }

            CHECK_ERROR(concurrentOperations(_d_root, d_keys, d_values, d_ops, count));

            if (source == SourceT::HOST) {
                CHECK_ERROR(memoryUtil::cpyToHost(d_values, values, count));
                CHECK_ERROR(memoryUtil::deviceFree(d_keys));
                CHECK_ERROR(memoryUtil::deviceFree(d_values));
                CHECK_ERROR(memoryUtil::deviceFree(d_ops));
            }

            return cudaSuccess;
        }
    };


    /**
     * Container class to handle usage of the secondary index. I spent a whole day fooling around
     * with templates and std::conditional, but honestly this is probably the easiest way to
     * do this.
     *
     * @tparam KeyT
     * @tparam ValueT
     * @tparam SizeT
     * @tparam AllocatorT
     */
    template<typename KeyT,
            typename ValueT,
            typename AllocatorT = BoolAllocator>
    class GpuBTreeMapSecondaryIndex {
        GpuBTreeMap<uint32_t, uint32_t, uint32_t, AllocatorT> map;
        SecondaryIndex<uint32_t, ValueT> secondaryIndex;


    public:
        explicit GpuBTreeMapSecondaryIndex(AllocatorT* mem_allocator = nullptr, int device_id = 0) : map(mem_allocator, device_id) {

        }

        cudaError_t init(AllocatorT mem_allocator, uint32_t* root_, int deviceId = 0) {
            return map.init(mem_allocator, root_, deviceId);
        }

        void free() {
            map.free();
        }

        __host__ __device__ AllocatorT* getAllocator() { return map.getAllocator(); }
        __host__ __device__ uint32_t* getRoot() { return map.getRoot(); }

        /**
         * This can only handle searches and insertions.
         * @param keys
         * @param values
         * @param ops
         * @param count
         * @return
         */
        void diyConcurrentOperations(KeyT* keys,
                                            ValueT* values,
                                            OperationT* ops,
                                            uint32_t count) {

            std::vector<uint32_t> keys_narrow;
            std::vector<uint32_t> values_hash;
            keys_narrow.reserve(count);
            values_hash.reserve(count);

            for (uint32_t i = 0; i < count; ++i) {
                // Narrow all of the keys.
                keys_narrow[i] = static_cast<uint32_t>(keys[i]);

                // Put insertion values into the secondary index.
                if (ops[i] == OperationT::INSERT) {
                    uint8_t loc;
                    uint32_t hash;
                    SIBucket<uint32_t, ValueT>* b = secondaryIndex.alloc(loc, hash);

                    std::pair<uint32_t, ValueT> p = {keys_narrow[i], values[i]};
                    (*b).set(loc, p);
                    values_hash[i] = hash;
                }
            }

            // Split delete keys into their own kernel invocation
            std::vector<uint32_t> delete_keys;
            for (uint32_t i = 0; i < count; ++i) {
                if (ops[i] == OperationT::DELETE) {
                    delete_keys.push_back(keys[i]);
                }
            }

            // Execute searches/insertions on GPU
            map.concurrentOperations(keys_narrow.data(), values_hash.data(), ops, count, SourceT::HOST);

            // Execute deletes on GPU (Deletes don't return anything, this may be an issue).
            map.deleteKeys(delete_keys.data(), delete_keys.size(), SourceT::HOST);

            // Postprocess, hash lookup all of the old values.
            std::vector<uint32_t> dealloc;
            for (int i = 0; i < count; i++) {
                if (ops[i] == OperationT::QUERY) {
                    uint32_t val = values_hash[i];
                    std::pair<uint32_t, ValueT> p;
                    SIBucket<uint32_t, ValueT>* b = secondaryIndex.getBucket(val);
                    // 0xFF narrows val to just one byte.
                    b->get(val & 0xFF, p);

                    // If the key matches, replace the value with the looked up one.
                    if(keys_narrow[i] == p.first) {
                        values[i] = p.second;
                    }
                }
                // TODO: Removes are not supported in the kernel, but we need to free space in the secondary index.
                else if(ops[i] == OperationT::DELETE){
                    dealloc.push_back(values_hash[i]);
                }
            }
            for (auto &d : dealloc){
                SIBucket<uint32_t,ValueT>* b = secondaryIndex.getBucket(d);
                b->free(d & 0xFF);
            }
        }
    };
}
#endif
