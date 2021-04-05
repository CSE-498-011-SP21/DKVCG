/**
 * @file
 */

#include <KVCache.hh>

#ifndef KVCG_CACHE_CUH
#define KVCG_CACHE_CUH

/**
 * KVCache caches keys and values
 * K is the key type
 * V is the value type
 * DSCaching is a data structure that is being cached by this cache
 * SETS is the number of SETs in the cache
 * N is the number of elements per set
 * @tparam SETS
 * @tparam N
 */
template<unsigned SETS = 524288 / sizeof(kvgpu::LockingPair<unsigned long long, data_t *>) / 8, unsigned N = 8>
class KVCacheWrapper {
private:
    using K = unsigned long long;
public:
    /**
     * Creates cache
     */
    KVCacheWrapper()
            : cache() {

    }

    /**
     * Removes cache
     */
    ~KVCacheWrapper() {}

    std::pair<bool, data_t *> get(K key, unsigned hash, const kvgpu::Model<K> &mfn) {
        auto pair = cache.fast_get(key, hash, mfn);

        if (pair.first == nullptr || pair.first->valid != 1) {
            return {true, nullptr};
        } else {
            if (pair.first->value == nullptr) {
                return {true, nullptr};
            }
            auto cpy = new data_t(pair.first->value->size);
            memcpy(cpy->data, pair.first->value->data, cpy->size);
            return {false, cpy};
        }
    }

    /**
     *
     * @param key
     * @param value
     * @param hash
     * @param mfn
     * @return
     */
    inline data_t *put(K key, data_t *value, unsigned hash, const kvgpu::Model<K> &mfn) {
        auto pair = cache.get_with_log(key, hash, mfn);
        assert(std::get<0>(pair));
        data_t *old_value = std::get<0>(pair)->value;

        std::get<0>(pair)->value = value;
        std::get<0>(pair)->deleted = 0;
        std::get<0>(pair)->valid = 1;
        cache.log_requests->operator[](std::get<2>(pair)) = REQUEST_INSERT;
        cache.log_hash->operator[](std::get<2>(pair)) = hash;
        cache.log_keys->operator[](std::get<2>(pair)) = key;
        cache.log_values->operator[](std::get<2>(pair)) = value;

        return old_value;
    }

    /**
     *
     * @param key
     * @param value
     * @param hash
     * @param mfn
     * @return
     */
    inline data_t *remove(K key, data_t *value, unsigned hash, const kvgpu::Model<K> &mfn) {
        auto pair = cache.get_with_log(key, hash, mfn);
        assert(std::get<0>(pair));

        data_t *old_value = std::get<0>(pair)->value;
        std::get<0>(pair)->value = nullptr;
        std::get<0>(pair)->deleted = 1;
        std::get<0>(pair)->valid = 1;

        cache.log_requests->operator[](std::get<2>(pair)) = REQUEST_REMOVE;
        cache.log_hash->operator[](std::get<2>(pair)) = hash;
        cache.log_keys->operator[](std::get<2>(pair)) = key;

        return old_value;
    }


    /**
     * Returns value that should be written to client. Insert (do not do PUT) the value into the map.
     * Return a copy of what is in the map at the end of the insert.
     * @param key
     * @param value
     * @param hash
     * @param mfn
     * @return
     */
    inline data_t *missCallback(K key, data_t *value, unsigned hash, const kvgpu::Model<K> &mfn) {
        auto cacheRes = cache.internal_get(key, hash, mfn);

        data_t *cpy = nullptr;

        if (cacheRes.first->valid == 1) {
            if (cacheRes.first->deleted == 0 && cacheRes.first->value) {
                cpy = new data_t(cacheRes.first->value->size);
                memcpy(cpy->data, cacheRes.first->value->data, cpy->size);
            }
        } else {
            cacheRes.first->valid = 1;
            cacheRes.first->value = value;
            cacheRes.first->deleted = (value == nullptr);
            if (cacheRes.first->deleted == 0 && cacheRes.first->value) {
                cpy = new data_t(cacheRes.first->value->size);
                memcpy(cpy->data, cacheRes.first->value->data, cpy->size);
            }
        }

        return cpy;
    }

    template<typename H>
    void scan_and_evict(const kvgpu::Model<K> &mfn, const H &hfn, std::unique_lock<std::mutex> modelLock) {
        cache.scan_and_evict(mfn, hfn, std::move(modelLock));
    }


    constexpr size_t getN() {
        return N;
    }

    constexpr size_t getSETS() {
        return SETS;
    }

    void stat() {
        //std::cout << "Cache Expansions " << expansions << std::endl;
        //std::cout << "Footprint without expansions: " << (sizeof(*this) + sizeof(LockingPair<K,V>) * SETS * N) / 1024.0 / 1024.0 << " MB" << std::endl;
    }


    tbb::concurrent_vector<int> *&getLogRequests() {
        return cache.log_requests;
    }

    tbb::concurrent_vector<unsigned> *&getLogHash() {
        return cache.log_hash;
    }

    tbb::concurrent_vector<K> *&getLogKeys() {
        return cache.log_keys;
    }

    tbb::concurrent_vector<data_t *> *&getLogValues() {
        return cache.log_values;
    }

    std::atomic_size_t &getLogSize() {
        return cache.log_size;
    }


private:

    kvgpu::KVCache<K, data_t *, SETS, N> cache;

};

/**
 * Type to be used by GPU.
 */
class Cache {
public:
    typedef KVCacheWrapper<1000000, 8> type;
};

#endif //KVCG_CACHE_CUH
