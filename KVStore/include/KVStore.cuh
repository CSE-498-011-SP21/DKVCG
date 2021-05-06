/**
 * @file
 */

#include <utility>
#include <memory>
#include <atomic>
#include <Cache.hh>
#include <Slab.cuh>
#include <StandardSlabDefinitions.cuh>
#include <mutex>
#include <iostream>
#include <tbb/concurrent_queue.h>
#include <tbb/concurrent_vector.h>
#include <Slabs.cuh>
#include <BTrees.cuh>

// TODO implement EBR with 2 rounds of streams before freeing

#ifndef KVGPU_KVSTORE_CUH
#define KVGPU_KVSTORE_CUH

int SLAB_SIZE = 1000000;

const std::vector<PartitionedSlabUnifiedConfig> STANDARD_CONFIG = {{SLAB_SIZE, 0, cudaStreamDefault},
                                                                   {SLAB_SIZE, 1, cudaStreamDefault}};

template<typename M>
class KVStore {
public:

//    using Slab_t = Slabs<M>;
    using Slab_t = BTrees<M>;

    KVStore() : cache(std::make_shared<typename Cache::type>()), model(new M()) {
        slab = std::make_shared<Slab_t>(STANDARD_CONFIG, this->cache, model);
    }

    KVStore(const std::vector<PartitionedSlabUnifiedConfig> &conf) : cache(
            std::make_shared<typename Cache::type>()), model(new M()) {
        if (!conf.empty())
            slab = std::make_shared<Slab_t>(conf, this->cache, model);
    }

    KVStore(const std::vector<PartitionedSlabUnifiedConfig> &conf, const std::string &filename) : cache(
            std::make_shared<typename Cache::type>()), model(new M(filename)) {
        if (!conf.empty())
            slab = std::make_shared<Slab_t>(conf, this->cache, model);
    }

    KVStore(const std::vector<PartitionedSlabUnifiedConfig> &conf, M &m) : cache(
            std::make_shared<typename Cache::type>()), model(new M(m)) {
        if (!conf.empty())
            slab = std::make_shared<Slab_t>(conf, this->cache, model);
    }


    KVStore(const KVStore<M> &other) : slab(other.slab), cache(other.cache), model(other.model) {

    }

    ~KVStore() {

    }

    std::shared_ptr<Slab_t> getSlab() {
        return slab;
    }

    std::shared_ptr<typename Cache::type> getCache() {
        return cache;
    }

    std::shared_ptr<M> getModel() {
        return model;
    }

private:

    std::shared_ptr<Slab_t> slab;
    std::shared_ptr<typename Cache::type> cache;
    std::shared_ptr<M> model;
};

#endif //KVGPU_KVSTORE_CUH
