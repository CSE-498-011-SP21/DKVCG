/**
 * @file
 */

#include <utility>
#include "KVStoreInternalClient.cuh"
#include <memory>
#include <atomic>
#include <exception>
#include "KVStoreCtx.cuh"

#include <faulttolerance/fault_tolerance.h>
namespace ft = cse498::faulttolerance;

#ifndef KVGPU_KVSTORECLIENT_CUH
#define KVGPU_KVSTORECLIENT_CUH

template< typename M>
class GeneralClient {
public:
    GeneralClient() {}

    virtual ~GeneralClient() {}

    virtual void batch(std::vector<RequestWrapper<unsigned long long, data_t *>> &req_vector,
                       std::shared_ptr<Communication> resBuf,
                       std::chrono::high_resolution_clock::time_point startTime) = 0;

    virtual void batch_drop_modifications(std::vector<RequestWrapper<unsigned long long, data_t *>> &req_vector,
                                          std::shared_ptr<Communication> resBuf,
                                          std::chrono::high_resolution_clock::time_point startTime) = 0;


    virtual tbb::concurrent_vector<std::pair<std::chrono::high_resolution_clock::time_point, std::vector<std::chrono::high_resolution_clock::time_point>>>
    getCacheTimes() = 0;

    // TBD: make private?
    ft::Server* logServer;

    virtual float hitRate() = 0;

    virtual void resetStats() = 0;

    virtual size_t getHits() = 0;

    virtual size_t getOps() = 0;

    virtual void stat() = 0;

    virtual std::future<void> change_model(std::atomic_bool &signal, M &newModel, block_t *block, double &time) = 0;

    virtual M getModel() = 0;

    virtual std::chrono::high_resolution_clock::time_point getStart() = 0;

    void batch(std::vector<RequestWrapper<unsigned long long, data_t *>> req_vector) {
        std::chrono::high_resolution_clock::time_point startTime = getStart();
        std::shared_ptr<Communication> resBuf;
        batch(req_vector, resBuf, startTime);
    }

};

template<typename M, typename Slab_t, bool UseCache = true, bool UseGPU = true>
struct ChooseInternalClient {
    static_assert(UseGPU || UseCache, "Need to use GPU or Use Cache");
    using type = KVStoreInternalClient<M, Slab_t>;

    static inline std::unique_ptr<type> getClient(KVStoreCtx<M> &ctx) {
        return ctx.getClient();
    };
};

template<typename M, typename Slab_t>
struct ChooseInternalClient<M, Slab_t, false, true> {
    using type = NoCacheKVStoreInternalClient<M, Slab_t>;

    static inline std::unique_ptr<type> getClient(KVStoreCtx<M> &ctx) {
        return ctx.getNoCacheClient();
    };

};

// true, true and false, true

template<typename M, typename Slab_t>
struct ChooseInternalClient<M, Slab_t, true, false> {
    using type = JustCacheKVStoreInternalClient<M, Slab_t>;

    static inline std::unique_ptr<type> getClient(KVStoreCtx<M> &ctx) {
        return ctx.getJustCacheClient();
    };

};

template<typename M, bool UseCache = true, bool UseGPU = true>
class KVStoreClient : public GeneralClient<M> {
private:
    using Slab_t = typename KVStoreCtx<M>::Slab_t;
    using ChooseType = ChooseInternalClient<M, Slab_t, UseCache, UseGPU>;
    using InternalType = typename ChooseType::type;
public:

    KVStoreClient() = delete;

    explicit KVStoreClient(KVStoreCtx<M> ctx) : client(std::move(ChooseType::getClient(ctx))) {
    }

    KVStoreClient(const KVStoreClient<M, UseCache, UseGPU> &) = delete;

    KVStoreClient(KVStoreClient<M, UseCache, UseGPU> &&other) {
        client = std::move(other.client);
        other.client = nullptr;
    }


    ~KVStoreClient() {

    }

    void batch(std::vector<RequestWrapper<unsigned long long, data_t *>> &req_vector,
               std::shared_ptr<Communication> resBuf,
               std::chrono::high_resolution_clock::time_point startTime) {
        client->batch(req_vector, resBuf, startTime);
    }

    void batch_drop_modifications(std::vector<RequestWrapper<unsigned long long, data_t *>> &req_vector,
                                  std::shared_ptr<Communication> resBuf,
                                  std::chrono::high_resolution_clock::time_point startTime) {
        client->batch_drop_modifications(req_vector, resBuf, startTime);
    }


    tbb::concurrent_vector<std::pair<std::chrono::high_resolution_clock::time_point, std::vector<std::chrono::high_resolution_clock::time_point>>>
    getCacheTimes() {
        return client->getCacheTimes();
    }

    float hitRate() {
        return client->hitRate();
    }

    void resetStats() {
        client->resetStats();
    }

    size_t getHits() {
        return client->getHits();
    }

    size_t getOps() {
        return client->getOps();
    }

    void stat() {
        return client->stat();
    }

    std::future<void> change_model(std::atomic_bool &signal, M &newModel, block_t *block, double &time) {
        return client->change_model(signal, newModel, block, time);
    }

    M getModel() {
        return client->getModel();
    }

    std::chrono::high_resolution_clock::time_point getStart() {
        return client->getStart();
    }

private:
    std::unique_ptr<InternalType> client;
};

template<typename M>
using NoCacheKVStoreClient = KVStoreClient<M, false, true>;

template<typename M>
using JustCacheKVStoreClient = KVStoreClient<M, true, false>;

#endif //KVGPU_KVSTORECLIENT_CUH
