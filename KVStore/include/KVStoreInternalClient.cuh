/**
 * @file
 */

#include "KVStore.cuh"
#include <functional>
#include <chrono>
#include <tbb/concurrent_queue.h>
#include <RequestWrapper.hh>

#ifndef KVGPU_KVSTOREINTERNALCLIENT_CUH
#define KVGPU_KVSTOREINTERNALCLIENT_CUH

int LOAD_THRESHOLD = BLOCKS * 10000;
const size_t Q_CAP = 2;

struct block_t {
    std::condition_variable cond;
    std::mutex mtx;
    int count;
    int crossing;

    block_t(int n) : count(n), crossing(0) {}

    void wait() {
        std::unique_lock<std::mutex> ulock(mtx);

        crossing++;

        // wait here

        cond.wait(ulock);
    }

    bool threads_blocked() {
        std::unique_lock<std::mutex> ulock(mtx);
        return crossing == count;
    }

    void wake() {
        std::unique_lock<std::mutex> ulock(mtx);
        cond.notify_all();
        crossing = 0;
    }

};

template<typename K, typename V>
void schedule_for_batch_helper(K *&keys, V *&values, unsigned *requests, unsigned *hashes,
                               std::unique_lock<kvgpu::mutex> *locks, unsigned *&correspondence,
                               int &index, const int &hash, const RequestWrapper<K, V> &req,
                               std::unique_lock<kvgpu::mutex> &&lock, int i) {

    keys[index] = req.key;
    values[index] = req.value;
    requests[index] = req.requestInteger;
    hashes[index] = hash;
    locks[index] = std::move(lock);
    correspondence[index] = i;
    index++;
}

thread_local int loadBalance = 0;
thread_local bool loadBalanceSet = false;

void init_loadbalance(int num_threads) {
    if (!loadBalanceSet) {
        unsigned seed = time(nullptr);
        loadBalance = rand_r(&seed) % num_threads;
        loadBalanceSet = true;
    }
}

/**
 * M is the type of the Model
 * @tparam M
 */
template<typename M, typename Slab_t = Slabs<M>, bool UseCache = true, bool UseGPU = true>
class KVStoreInternalClient {
public:
    using time_point = std::chrono::high_resolution_clock::time_point;

private:
    struct CPUStageArgs {

        CPUStageArgs() = default;

        ~CPUStageArgs() = default;

        std::vector<RequestWrapper<unsigned long long, data_t *>> req_vector;
        std::shared_ptr<Communication> resBuf;
        int sizeForGPUBatches;
        std::vector<std::pair<int, unsigned>> cache_batch_correspondence;
        bool dontDoGPU;
        time_point startTime;
    };

    using q_t = tbb::concurrent_bounded_queue<CPUStageArgs>;

public:

    KVStoreInternalClient(std::shared_ptr<Slab_t> s,
                          std::shared_ptr<typename Cache::type> c, std::shared_ptr<M> m,
                          int num_threads)
            : numslabs(
            UseGPU ? s->getNumslabs() : 0), slabs(s), cache(c), hits(0),
              operations(0),
              start(std::chrono::high_resolution_clock::now()),
              model(m), cpuStageQ(new q_t[num_threads]),
              num_threads_(num_threads) {
        reclaimExecution = false;

        for (int i = 0; i < num_threads; i++) {
            cpuStageQ[i].set_capacity(Q_CAP);
            cputhreads.emplace_back([this](int tid) {
                while (!reclaimExecution) {
                    CPUStageArgs a;
                    if (cpuStageQ[tid].try_pop(a)) {
                        cpuStage(a);
                    }
                }
            }, i);
        }
    }

    ~KVStoreInternalClient() {
        reclaimExecution = true;
        for (auto &t : cputhreads) {
            t.join();
        }
        delete[] cpuStageQ;
    }

    typedef RequestWrapper<unsigned long long, data_t *> RW;

    /**
     * Performs the batch of operations given
     * @param req_vector
     */
    void batch(std::vector<RequestWrapper<unsigned long long, data_t *>> &req_vector,
               std::shared_ptr<Communication> &resBuf,
               time_point startTime) {
        assert(loadBalanceSet);

        bool dontDoGPU = false;

        if (numslabs == 0 || slabs->getLoad() >= LOAD_THRESHOLD) {
            dontDoGPU = true;
        }

        //std::cerr << req_vector.size() << std::endl;
        //req_vector.size() % 512 == 0 &&
        //assert(req_vector.size() <= THREADS_PER_BLOCK * BLOCKS * numslabs);

        std::vector<std::pair<int, unsigned>> cache_batch_correspondence;

        cache_batch_correspondence.reserve(req_vector.size());
        std::vector<BatchData<unsigned long long> *> gpu_batches;

        gpu_batches.reserve(numslabs);

        int sizeForGPUBatches = route(req_vector, resBuf, cache_batch_correspondence, gpu_batches, startTime);

        sendGPUBatches(dontDoGPU, gpu_batches);

        loadBalance++;
        if (loadBalance == num_threads_)
            loadBalance = 0;

        cpuStageQ[loadBalance].push({/*.req_vector =*/ req_vector,
                                            /*.resBuf =*/ resBuf,
                                            /*.sizeForGPUBatches =*/ sizeForGPUBatches,
                                            /*.cache_batch_correspondence =*/ cache_batch_correspondence,
                                            /*.dontDoGPU =*/ dontDoGPU,
                                            /*.startTime =*/ startTime});
    }

    void batch_drop_modifications(std::vector<RequestWrapper<unsigned long long, data_t *>> &req_vector,
                                  std::shared_ptr<Communication> &resBuf,
                                  time_point startTime) {
        assert(loadBalanceSet);

        bool dontDoGPU = false;

        if (numslabs == 0 || slabs->getLoad() >= LOAD_THRESHOLD) {
            dontDoGPU = true;
        }

        //std::cerr << req_vector.size() << std::endl;
        //req_vector.size() % 512 == 0 &&
        //assert(req_vector.size() <= THREADS_PER_BLOCK * BLOCKS * numslabs);

        std::vector<std::pair<int, unsigned>> cache_batch_correspondence;

        cache_batch_correspondence.reserve(req_vector.size());
        std::vector<BatchData<unsigned long long> *> gpu_batches;

        gpu_batches.reserve(numslabs);

        int sizeForGPUBatches = route_drop_modifications(req_vector, resBuf, cache_batch_correspondence, gpu_batches,
                                                         startTime);

        sendGPUBatches(dontDoGPU, gpu_batches);

        loadBalance++;
        if (loadBalance == num_threads_)
            loadBalance = 0;

        cpuStageQ[loadBalance].push({/*.req_vector =*/ req_vector,
                                            /*.resBuf =*/ resBuf,
                                            /*.sizeForGPUBatches =*/ sizeForGPUBatches,
                                            /*.cache_batch_correspondence =*/ cache_batch_correspondence,
                                            /*.dontDoGPU =*/ dontDoGPU,
                                            /*.startTime =*/ startTime});
    }


    void cpuStage(CPUStageArgs &args) {

        std::vector<time_point> times;
        times.reserve(THREADS_PER_BLOCK);

        std::vector<BatchData<unsigned long long> *> gpu_batches2;
        gpu_batches2.reserve(numslabs);
        setUpMissBatches(args.req_vector, args.resBuf, gpu_batches2, args.startTime);

        //std::cerr << "Looking through cache now\n";

        for (auto &cache_batch_idx : args.cache_batch_correspondence) {

            auto req_vector_elm = args.req_vector[cache_batch_idx.first];

            if (req_vector_elm.requestInteger != REQUEST_EMPTY) {

                if (req_vector_elm.requestInteger == REQUEST_GET) {
                    auto pair = cache->get(req_vector_elm.key, cache_batch_idx.second, *model);
                    if (pair.first) {
                        onMiss(cache_batch_idx, gpu_batches2, req_vector_elm, args.resBuf,
                               times);
                    } else {
                        hits.fetch_add(1, std::memory_order_relaxed);
                        args.resBuf->send(Response(cache_batch_idx.first, pair.second, false));
                        times.push_back(std::chrono::high_resolution_clock::now());
                    }
                } else {
                    data_t *value;
                    switch (req_vector_elm.requestInteger) {
                        case REQUEST_INSERT:
                            //std::cerr << "Insert request\n";
                            hits++;

                            value = cache->put(req_vector_elm.key,
                                               req_vector_elm.value,
                                               cache_batch_idx.second,
                                               *model);

                            args.resBuf->send(Response(cache_batch_idx.first, value, false));
                            break;
                        case REQUEST_REMOVE:
                            //std::cerr << "RM request\n";
                            value = cache->remove(req_vector_elm.key,
                                                  req_vector_elm.value,
                                                  cache_batch_idx.second,
                                                  *model);
                            hits++;
                            asm volatile("":: : "memory");
                            args.resBuf->send(Response(cache_batch_idx.first, value, false));
                            break;
                    }
                    times.push_back(std::chrono::high_resolution_clock::now());
                }
            }
        }

        //std::cerr << "Done looking through cache now\n";

        asm volatile("":: : "memory");
        forwardMissBatch(args.dontDoGPU, gpu_batches2, args.sizeForGPUBatches, args.resBuf);
        // send gpu_batch2

        cacheTimes.push_back({args.startTime, times});

        operations += args.req_vector.size();
    }

    // single threaded
    std::future<void> change_model(std::atomic_bool &signal, M &newModel, block_t *block, double &time) {
        signal = true;

        std::unique_lock<std::mutex> modelLock(modelMtx);
        tbb::concurrent_vector<int> *log_requests = cache->getLogRequests();
        tbb::concurrent_vector<unsigned> *log_hash = cache->getLogHash();
        tbb::concurrent_vector<unsigned long long> *log_keys = cache->getLogKeys();
        tbb::concurrent_vector<data_t *> *log_values = cache->getLogValues();

        auto new_log_requests = new tbb::concurrent_vector<int>(cache->getN() * cache->getSETS());
        auto new_log_hash = new tbb::concurrent_vector<unsigned>(cache->getN() * cache->getSETS());
        auto new_log_keys = new tbb::concurrent_vector<unsigned long long>(cache->getN() * cache->getSETS());
        auto new_log_values = new tbb::concurrent_vector<data_t *>(cache->getN() * cache->getSETS());

        auto start = std::chrono::high_resolution_clock::now();
        asm volatile("":: : "memory");
        while (!block->threads_blocked());
        block->wake();
        //std::cerr << "All threads at barrier\n";

        cache->getLogRequests() = new_log_requests;
        cache->getLogHash() = new_log_hash;
        cache->getLogKeys() = new_log_keys;
        cache->getLogValues() = new_log_values;
        size_t tmpSize = cache->getLogSize();
        cache->getLogSize() = 0;

        int batchSizeUsed = std::min(THREADS_PER_BLOCK * BLOCKS,
                                     (int) (tmpSize / THREADS_PER_BLOCK + 1) * THREADS_PER_BLOCK);

        std::vector<std::pair<int, std::shared_ptr<Communication>>> vecOfBufs;

        for (int enqueued = 0; enqueued < tmpSize; enqueued += batchSizeUsed) {

            auto gpu_batches = std::vector<BatchData<unsigned long long> *>(numslabs);

            for (int i = 0; i < numslabs; ++i) {
                std::shared_ptr<Communication> resBuf = std::make_shared<LocalCommunication>(
                        batchSizeUsed);
                gpu_batches[i] = new BatchData<unsigned long long>(0,
                                                                   resBuf,
                                                                   batchSizeUsed, start);
                gpu_batches[i]->resBufStart = 0;
                //gpu_batches[i]->flush = true;
            }

            int numberNonEmpty = 0;

            for (int i = 0; i + enqueued < tmpSize && i < batchSizeUsed; ++i) {
                int gpuToUse = log_hash->operator[](i + enqueued) % numslabs;
                int idx = gpu_batches[gpuToUse]->idx;
                gpu_batches[gpuToUse]->idx++;
                gpu_batches[gpuToUse]->keys[idx] = log_keys->operator[](i + enqueued);
                gpu_batches[gpuToUse]->values[idx] = log_values->operator[](i + enqueued);
                gpu_batches[gpuToUse]->requests[idx] = log_requests->operator[](i + enqueued);
                if (gpu_batches[gpuToUse]->requests[idx] != REQUEST_EMPTY) {
                    numberNonEmpty++;
                }
                gpu_batches[gpuToUse]->hashes[idx] = log_hash->operator[](i + enqueued);
            }

            for (int i = 0; i < numslabs; ++i) {
                if (gpu_batches[i]->idx == 0) {
                    delete gpu_batches[i];
                } else {
                    slabs->increaseLoad();
                    slabs->batch(gpu_batches[i], i);
                    vecOfBufs.push_back({numberNonEmpty, gpu_batches[i]->resBuf});
                }
            }

        }

        for (std::pair<int, std::shared_ptr<Communication>> &r : vecOfBufs) {

            int count = 0;
            do {
                Response response;
                if (r.second->try_recv(response)) {
                    count++;
                }
            } while (count < r.first);
        }
        asm volatile("":: : "memory");
        *model = newModel;
        asm volatile("":: : "memory");
        signal = false;
        auto end = std::chrono::high_resolution_clock::now();
        time = std::chrono::duration<double>(end - start).count();

        return std::async([this](std::unique_lock<std::mutex> l) {
            std::hash<unsigned long long> h;
            cache->scan_and_evict(*(this->model), h, std::move(l));
        }, std::move(modelLock));
    }

    M getModel() {
        return *model;
    }

    float hitRate() {
        return (double) hits / operations;
    }

    size_t getOps() {
        if (numslabs == 0)
            return 0;
        return slabs->getOps();
    }

    size_t getHits() {
        return hits;
    }

    void resetStats() {
        hits = 0;
        operations = 0;
        if (numslabs != 0)
            slabs->clearMops();
        cacheTimes.clear();
    }

    void stat() {
        for (int i = 0; i < numslabs; i++) {
            std::cout << "TABLE: GPU Info " << i << std::endl;
            std::cout
                    << "Time from start (s)\tTime spent responding (ms)\tTime in batch fn (ms)\tTime Dequeueing (ms)\tFraction that goes to cache\tDuration (ms)\tFill\tThroughput GPU "
                    << i << " (Mops)\tQ Time till batch fn (ms)" << std::endl;
            for (StatData &s : slabs->getMops()[i]) {

                std::cout << std::chrono::duration<double>(s.timestampEnd - start).count() << "\t"
                          << std::chrono::duration<double>(s.timestampEnd - s.timestampWriteBack).count() * 1e3 << "\t"
                          << std::chrono::duration<double>(s.timestampWriteBack - s.timestampStartBatch).count() * 1e3
                          << "\t"
                          << std::chrono::duration<double>(s.timestampStartBatch - s.timestampDequeueToBatch).count() *
                             1e3 << "\t"
                          << s.timesGoingToCache / (double) s.size << "\t"
                          << s.duration << "\t" << (double) s.size / THREADS_PER_BLOCK / BLOCKS << "\t"
                          << s.size / s.duration / 1e3
                          << "\t"
                          << std::chrono::duration<double>(s.timestampStartBatch - s.sampleQTime).count() * 1e3
                          << std::endl;
            }
            std::cout << std::endl;
        }
        cache->stat();
    }

    tbb::concurrent_vector<std::pair<time_point, std::vector<time_point>>> getCacheTimes() {
        return cacheTimes;
    }

    time_point getStart() {
        return start;
    }

private:

    template<typename V1 = data_t *, std::enable_if_t<std::is_same<data_t *, V1>::value> * = nullptr>
    V1 handle_copy(std::pair<kvgpu::LockingPair<unsigned long long, data_t *> *, kvgpu::sharedlocktype> &pair) {
        data_t *cpy = nullptr;
        if (pair.first->deleted == 0 && pair.first->value) {
            cpy = new data_t(pair.first->value->size);
            memcpy(cpy->data, pair.first->value->data, cpy->size);
        }
        return cpy;
    }

    template<typename V1 = data_t *, std::enable_if_t<!std::is_same<data_t *, V1>::value> * = nullptr>
    V1 handle_copy(std::pair<kvgpu::LockingPair<unsigned long long, data_t *> *, kvgpu::sharedlocktype> &pair) {
        std::cerr << "Why is this being used?" << std::endl;
        _exit(1);
        if (pair.first->deleted == 0 && pair.first->value) {
            return pair.first->value;
        }
        return EMPTY<V1>::value;
    }

    // normal
    /// returns response location in resbuf
    template<bool UseCache_ = UseCache, typename std::enable_if_t<(UseCache_ && UseGPU)> * = nullptr>
    inline int
    route(std::vector<RequestWrapper<unsigned long long, data_t *>> &req_vector,
          std::shared_ptr<Communication> &resBuf,
          std::vector<std::pair<int, unsigned>> &cache_batch_corespondance,
          std::vector<BatchData<unsigned long long> *> &gpu_batches, time_point startTime) {

        for (int i = 0; i < numslabs; ++i) {
            gpu_batches.push_back(new BatchData<unsigned long long>(0, resBuf, req_vector.size(), startTime));
        }

        for (int i = 0; i < req_vector.size(); ++i) {
            RW req = req_vector[i];
            if (req.requestInteger != REQUEST_EMPTY) {
                unsigned h = hfn(req.key);
                if (model->operator()(req.key, h)) {
                    cache_batch_corespondance.push_back({i, h});
                } else {
                    int gpuToUse = h % numslabs;
                    int idx = gpu_batches[gpuToUse]->idx;
                    gpu_batches[gpuToUse]->idx++;
                    gpu_batches[gpuToUse]->keys[idx] = req.key;
                    gpu_batches[gpuToUse]->values[idx] = req.value;
                    gpu_batches[gpuToUse]->requests[idx] = req.requestInteger;
                    gpu_batches[gpuToUse]->hashes[idx] = h;
                }
            }
        }

        int sizeForGPUBatches = 0; //cache_batch_corespondance.size();
        for (int i = 0; i < numslabs; ++i) {
            gpu_batches[i]->resBufStart = sizeForGPUBatches;
            sizeForGPUBatches += gpu_batches[i]->idx;
        }
        return sizeForGPUBatches;
    }

    // just cache
    template<bool UseCache_ = UseCache, typename std::enable_if_t<(UseCache_ && !UseGPU)> * = nullptr>
    inline int
    route(std::vector<RequestWrapper<unsigned long long, data_t *>> &req_vector,
          std::shared_ptr<Communication> &resBuf,
          std::vector<std::pair<int, unsigned>> &cache_batch_corespondance,
          std::vector<BatchData<unsigned long long> *> &gpu_batches, time_point startTime) {

        for (int i = 0; i < req_vector.size(); ++i) {
            RW req = req_vector[i];
            if (req.requestInteger != REQUEST_EMPTY) {
                unsigned h = hfn(req.key);
                cache_batch_corespondance.push_back({i, h});
            }
        }

        int sizeForGPUBatches = 0; //cache_batch_corespondance.size();
        return sizeForGPUBatches;
    }

    // GPU only
    template<bool UseCache_ = UseCache, typename std::enable_if_t<!UseCache_> * = nullptr>
    inline int
    route(std::vector<RequestWrapper<unsigned long long, data_t *>> &req_vector,
          std::shared_ptr<Communication> &resBuf,
          std::vector<std::pair<int, unsigned>> &cache_batch_corespondance,
          std::vector<BatchData<unsigned long long> *> &gpu_batches, time_point startTime) {

        for (int i = 0; i < numslabs; ++i) {
            gpu_batches.push_back(new BatchData<unsigned long long>(0, resBuf, req_vector.size(), startTime));
        }

        for (int i = 0; i < req_vector.size(); ++i) {
            RW req = req_vector[i];
            if (req.requestInteger != REQUEST_EMPTY) {
                unsigned h = hfn(req.key);
                int gpuToUse = h % numslabs;
                int idx = gpu_batches[gpuToUse]->idx;
                gpu_batches[gpuToUse]->idx++;
                gpu_batches[gpuToUse]->keys[idx] = req.key;
                gpu_batches[gpuToUse]->values[idx] = req.value;
                gpu_batches[gpuToUse]->requests[idx] = req.requestInteger;
                gpu_batches[gpuToUse]->hashes[idx] = h;
                gpu_batches[gpuToUse]->requestID[idx] = i;
            }
        }

        int sizeForGPUBatches = 0; //cache_batch_corespondance.size();
        for (int i = 0; i < numslabs; ++i) {
            gpu_batches[i]->resBufStart = sizeForGPUBatches;
            sizeForGPUBatches += gpu_batches[i]->idx;
        }
        return sizeForGPUBatches;
    }

    template<bool UseCache_ = UseCache, typename std::enable_if_t<(UseCache_ && UseGPU)> * = nullptr>
    inline int
    route_drop_modifications(std::vector<RequestWrapper<unsigned long long, data_t *>> &req_vector,
                             std::shared_ptr<Communication> &resBuf,
                             std::vector<std::pair<int, unsigned>> &cache_batch_corespondance,
                             std::vector<BatchData<unsigned long long> *> &gpu_batches, time_point startTime) {

        for (int i = 0; i < numslabs; ++i) {
            gpu_batches.push_back(new BatchData<unsigned long long>(0, resBuf, req_vector.size(), startTime));
        }

        for (int i = 0; i < req_vector.size(); ++i) {
            RW req = req_vector[i];
            if (req.requestInteger == REQUEST_GET) {
                unsigned h = hfn(req.key);
                if (model->operator()(req.key, h)) {
                    cache_batch_corespondance.push_back({i, h});
                } else {
                    int gpuToUse = h % numslabs;
                    int idx = gpu_batches[gpuToUse]->idx;
                    gpu_batches[gpuToUse]->idx++;
                    gpu_batches[gpuToUse]->keys[idx] = req.key;
                    gpu_batches[gpuToUse]->values[idx] = req.value;
                    gpu_batches[gpuToUse]->requests[idx] = req.requestInteger;
                    gpu_batches[gpuToUse]->hashes[idx] = h;
                    gpu_batches[gpuToUse]->requestID[idx] = i;
                }
            } else if (req.requestInteger == REQUEST_REMOVE || req.requestInteger == REQUEST_INSERT) {
                resBuf->send(Response(i, nullptr, true));
            }
        }

        int sizeForGPUBatches = 0; //cache_batch_corespondance.size();
        for (int i = 0; i < numslabs; ++i) {
            gpu_batches[i]->resBufStart = sizeForGPUBatches;
            sizeForGPUBatches += gpu_batches[i]->idx;
        }
        return sizeForGPUBatches;
    }

    // just cache
    template<bool UseCache_ = UseCache, typename std::enable_if_t<(UseCache_ && !UseGPU)> * = nullptr>
    inline int
    route_drop_modifications(std::vector<RequestWrapper<unsigned long long, data_t *>> &req_vector,
                             std::shared_ptr<Communication> &resBuf,
                             std::vector<std::pair<int, unsigned>> &cache_batch_corespondance,
                             std::vector<BatchData<unsigned long long> *> &gpu_batches, time_point startTime) {

        for (int i = 0; i < req_vector.size(); ++i) {
            RW req = req_vector[i];
            if (req.requestInteger == REQUEST_GET) {
                unsigned h = hfn(req.key);
                cache_batch_corespondance.push_back({i, h});
            } else if (req.requestInteger == REQUEST_REMOVE || req.requestInteger == REQUEST_INSERT) {
                resBuf->send(Response(i, nullptr, true));
            }
        }

        int sizeForGPUBatches = 0; //cache_batch_corespondance.size();
        return sizeForGPUBatches;
    }

    // GPU only
    template<bool UseCache_ = UseCache, typename std::enable_if_t<!UseCache_> * = nullptr>
    inline int
    route_drop_modifications(std::vector<RequestWrapper<unsigned long long, data_t *>> &req_vector,
                             std::shared_ptr<Communication> &resBuf,
                             std::vector<std::pair<int, unsigned>> &cache_batch_corespondance,
                             std::vector<BatchData<unsigned long long> *> &gpu_batches, time_point startTime) {

        for (int i = 0; i < numslabs; ++i) {
            gpu_batches.push_back(new BatchData<unsigned long long>(0, resBuf, req_vector.size(), startTime));
        }

        for (int i = 0; i < req_vector.size(); ++i) {
            RW req = req_vector[i];
            if (req.requestInteger == REQUEST_GET) {
                unsigned h = hfn(req.key);
                int gpuToUse = h % numslabs;
                int idx = gpu_batches[gpuToUse]->idx;
                gpu_batches[gpuToUse]->idx++;
                gpu_batches[gpuToUse]->keys[idx] = req.key;
                gpu_batches[gpuToUse]->values[idx] = req.value;
                gpu_batches[gpuToUse]->requests[idx] = req.requestInteger;
                gpu_batches[gpuToUse]->hashes[idx] = h;
                gpu_batches[gpuToUse]->requestID[idx] = i;

            } else if (req.requestInteger == REQUEST_REMOVE || req.requestInteger == REQUEST_INSERT) {
                resBuf->send(Response(i, nullptr, true));
            }
        }

        int sizeForGPUBatches = 0; //cache_batch_corespondance.size();
        for (int i = 0; i < numslabs; ++i) {
            gpu_batches[i]->resBufStart = sizeForGPUBatches;
            sizeForGPUBatches += gpu_batches[i]->idx;
        }
        return sizeForGPUBatches;
    }

    // gpu only and normal
    template<bool UseGPU_ = UseGPU, typename std::enable_if_t<UseGPU_> * = nullptr>
    inline void sendGPUBatches(bool &dontDoGPU, std::vector<BatchData<unsigned long long> *> &gpu_batches) {
        if (!dontDoGPU) {
            for (int i = 0; i < numslabs; ++i) {
                slabs->increaseLoad();
                slabs->batch(gpu_batches[i], i);
            }
        } else {
            for (int i = 0; i < numslabs; ++i) {

                for (int idx = 0; idx < gpu_batches[i]->idx; idx++) {
                    gpu_batches[i]->resBuf->send(Response(gpu_batches[i]->requestID[idx], nullptr, true));
                }

                delete gpu_batches[i];
            }
        }
    }

    // cpu only
    template<bool UseGPU_ = UseGPU, typename std::enable_if_t<!UseGPU_> * = nullptr>
    inline void sendGPUBatches(bool &dontDoGPU, std::vector<BatchData<unsigned long long> *> &gpu_batches) {}

    // normal
    template<bool UseGPU_ = UseGPU, typename std::enable_if_t<UseCache && UseGPU_> * = nullptr>
    inline void setUpMissBatches(std::vector<RequestWrapper<unsigned long long, data_t *>> &req_vector,
                                 std::shared_ptr<Communication> &resBuf,
                                 std::vector<BatchData<unsigned long long> *> &gpu_batches2,
                                 time_point startTime) {
        for (int i = 0; i < numslabs; ++i) {
            gpu_batches2.push_back(new BatchData<unsigned long long>(0, resBuf, req_vector.size(), startTime));
        }
    }

    // gpu only or cpu only
    template<bool UseGPU_ = UseGPU, typename std::enable_if_t<
            (UseCache && !UseGPU_) || (!UseCache && UseGPU_)> * = nullptr>
    inline void setUpMissBatches(std::vector<RequestWrapper<unsigned long long, data_t *>> &req_vector,
                                 std::shared_ptr<Communication> &resBuf,
                                 std::vector<BatchData<unsigned long long> *> &gpu_batches2,
                                 time_point startTime) {}

    // normal
    template<bool UseGPU_ = UseGPU, typename std::enable_if_t<UseCache && UseGPU_> * = nullptr>
    inline void onMiss(std::pair<int, unsigned int> &cache_batch_idx,
                       std::vector<BatchData<unsigned long long> *> &gpu_batches2,
                       RequestWrapper<unsigned long long, data_t *> &req_vector_elm,
                       std::shared_ptr<Communication> &resBuf,
                       std::vector<time_point> &times) {
        int gpuToUse = cache_batch_idx.second % numslabs;
        int idx = gpu_batches2[gpuToUse]->idx;
        gpu_batches2[gpuToUse]->idx++;
        gpu_batches2[gpuToUse]->keys[idx] = req_vector_elm.key;
        gpu_batches2[gpuToUse]->requests[idx] = req_vector_elm.requestInteger;
        gpu_batches2[gpuToUse]->hashes[idx] = cache_batch_idx.second;
        gpu_batches2[gpuToUse]->handleInCache[idx] = true;
        gpu_batches2[gpuToUse]->requestID[idx] = cache_batch_idx.first;

    }

    // cache only
    template<bool UseGPU_ = UseGPU, typename std::enable_if_t<UseCache && !UseGPU_> * = nullptr>
    inline void onMiss(std::pair<int, unsigned int> &cache_batch_idx,
                       std::vector<BatchData<unsigned long long> *> &gpu_batches2,
                       RequestWrapper<unsigned long long, data_t *> &req_vector_elm,
                       std::shared_ptr<Communication> &resBuf,
                       std::vector<time_point> &times) {
        hits.fetch_add(1, std::memory_order_relaxed);
        std::cerr << "Sending\n";
        resBuf->send(Response(cache_batch_idx.first, nullptr, false));
        times.push_back(std::chrono::high_resolution_clock::now());
    }

    // gpu only
    template<bool UseGPU_ = UseGPU, typename std::enable_if_t<!UseCache && UseGPU_> * = nullptr>
    inline void onMiss(std::pair<int, unsigned int> &cache_batch_idx,
                       std::vector<BatchData<unsigned long long> *> &gpu_batches2,
                       RequestWrapper<unsigned long long, data_t *> &req_vector_elm,
                       std::shared_ptr<Communication> &resBuf,
                       std::vector<time_point> &times) {
        // should never be called
        assert(false);
    }


    // normal
    template<bool UseGPU_ = UseGPU, typename std::enable_if_t<UseCache && UseGPU_> * = nullptr>
    inline void
    forwardMissBatch(bool &dontDoGPU, std::vector<BatchData<unsigned long long> *> &gpu_batches2,
                     int &sizeForGPUBatches,
                     std::shared_ptr<Communication> &resBuf) {
        if (!dontDoGPU) {
            for (int i = 0; i < numslabs; ++i) {
                if (gpu_batches2[i]->idx > 0) {
                    gpu_batches2[i]->resBufStart = sizeForGPUBatches;
                    sizeForGPUBatches += gpu_batches2[i]->idx;
                    slabs->increaseLoad();
                    slabs->batch(gpu_batches2[i], i);
                } else {
                    delete gpu_batches2[i];
                }
            }
        } else {
            for (int i = 0; i < numslabs; ++i) {
                for (int idx = 0; idx < gpu_batches2[i]->idx; idx++) {
                    gpu_batches2[i]->resBuf->send(Response(gpu_batches2[i]->requestID[idx], nullptr, true));
                }

                delete gpu_batches2[i];
            }
        }
    }

    // cache only
    template<bool UseGPU_ = UseGPU, typename std::enable_if_t<(UseCache && !UseGPU_)> * = nullptr>
    inline void
    forwardMissBatch(bool &dontDoGPU, std::vector<BatchData<unsigned long long> *> &gpu_batches2,
                     int &sizeForGPUBatches,
                     std::shared_ptr<Communication> &resBuf) {}

    // gpu only
    template<bool UseGPU_ = UseGPU, typename std::enable_if_t<!UseCache && UseGPU_> * = nullptr>
    inline void
    forwardMissBatch(bool &dontDoGPU, std::vector<BatchData<unsigned long long> *> &gpu_batches2,
                     int &sizeForGPUBatches,
                     std::shared_ptr<Communication> &resBuf) {
        // should never be called
        assert(false);
    }

    int numslabs;
    std::mutex mtx;
    std::shared_ptr<Slab_t> slabs;
    //SlabUnified<K,V> *slabs;
    std::shared_ptr<typename Cache::type> cache;
    std::hash<unsigned long long> hfn;
    std::atomic_size_t hits;
    std::atomic_size_t operations;
    std::shared_ptr<M> model;
    time_point start;
    tbb::concurrent_vector<std::pair<time_point, std::vector<time_point>>> cacheTimes;
    std::atomic_bool reclaimExecution;
    std::vector<std::thread> cputhreads;
    q_t *cpuStageQ;
    int num_threads_;
    std::mutex modelMtx;
};

template<typename M, typename Slab_t = Slabs<M>>
using NoCacheKVStoreInternalClient = KVStoreInternalClient<M, Slab_t, false, true>;

template<typename M, typename Slab_t = Slabs<M>>
using JustCacheKVStoreInternalClient = KVStoreInternalClient<M, Slab_t, true, false>;

#endif //KVGPU_KVSTOREINTERNALCLIENT_CUH
