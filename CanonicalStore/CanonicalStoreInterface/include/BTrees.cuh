/**
 * @file
 */

#include <gpuSystemConfig.cuh>
#include <BatchData.cuh>
#include "StatData.cuh"
#include <Cache.hh>
#include "GpuBTree.h"

#ifndef KVCG_BTREES_HH
#define KVCG_BTREES_HH

/**
 * Copy of Slabs. This is to serve as a BTree container.
 * @tparam M the Model
 */
template<typename M>
struct BTrees {
    const int MAX_ATTEMPTS = 1;

    using V = data_t *;
    using VType = data_t *;

    BTrees() = delete;

    // TODO: Does this still need to be concurrent if we have only a single stream per GPU?
    typedef tbb::concurrent_queue<BatchData<unsigned long long> *> q_t;

    /**
     * This is a pool of thread which each reads from a concurrent queue "gpu_qs". The queue contains a pointer to "BatchData"
     * @param config Vector of configs, one per CUDA Stream
     * @param cache KVCacheWrapper defined in Cache.hh, The Hot Cache on the CPU?
     * @param m The Model, AnalyticalModel in Model.hh
     */
    BTrees(const std::vector<PartitionedSlabUnifiedConfig> &config,
          std::shared_ptr<typename Cache::type> cache, std::shared_ptr<M> m) : done(false),
                                                                               mops(new tbb::concurrent_vector<StatData>[config.size()]),
                                                                               _cache(cache), ops(0),
                                                                               load(0), model(m) {

        std::unordered_map<int, std::shared_ptr<GpuBTree::GpuBTreeMapSecondaryIndex<unsigned long long, V>>> gpus;
        // Populates the map. If a SlabUnified is not assigned to the GPU, create one and assign it.
        for (auto c : config) {
            if (gpus.find(c.gpu) == gpus.end())
                gpus[c.gpu] = std::make_shared<GpuBTree::GpuBTreeMapSecondaryIndex<unsigned long long, V>>();
            else {
                // This means we've already slabed this gpu. As multiple streams on the same GPU is not valid for the BTree,
                // We need to throw an error
                throw std::runtime_error("BTrees are not able to be used with multiple streams on the same GPU\nChange to using Slabs if you want multiple streams.\n");
            }
        }

        // One batching queue for each GPU we have slabbed.
        gpu_qs = new q_t[gpus.size()];
        numslabs = gpus.size();

        // For each stream, start a thread which listens to the queue for that GPU.
        for (int i = 0; i < config.size(); i++) {
            //config[i].stream;
            threads.emplace_back(threadFunction, i, config[i].gpu, gpus[config[i].gpu], config[i].stream);
        }
    }

    /**
     * Auto is not allowed for static members of a struct.
     */
    std::function<void(int, int, std::shared_ptr<GpuBTree::GpuBTreeMapSecondaryIndex<unsigned long long, V>>, cudaStream_t)>
            threadFunction = [this](int tid, int gpu, std::shared_ptr<GpuBTree::GpuBTreeMapSecondaryIndex<unsigned long long, V>> btree, cudaStream_t stream) {

        // Sets the device that subsequent CUDA operations will work on.
        gpuErrchk(cudaSetDevice(gpu));

        // Not sure what the BatchBuffer is used for. It seems to use a custom GroupAllocator,
        // which allocates according to "Group Affinity". Seems to be a custom memory location
        // where we can buffer data before sending it to the GPU.
        auto batchData = new BatchBuffer<unsigned long long, V>();

        unsigned long long *keys = batchData->getBatchKeys();
        V *values = batchData->getBatchValues();
        int *requests = batchData->getBatchRequests();
        unsigned *hashes = batchData->getHashValues();

        // BatchData has fields for request info and a response buffer. However, I'm not
        // exactly sure what holdonto is used for.
        BatchData<unsigned long long> *holdonto = nullptr;

        std::vector<std::pair<int, BatchData<unsigned long long> * >> writeBack;
        writeBack.reserve(THREADS_PER_BLOCK * BLOCKS / 512);
        std::chrono::high_resolution_clock::time_point sampleTime;
        bool sampleTimeSet = false;
        int index = THREADS_PER_BLOCK * BLOCKS;

        // Done with setup, this is what the thread does until Slabs is destructed. Would it be better for
        // all of these threads to use a condvar and wake up when there's data?
        // Maybe this "done" atomic would be a point of contention.
        // Though it's possible that each thread spends most of its time in the "batching" stage.
        while (!done.load()) {
            // Clear the writeBack & Set all of the requests to empty.
            writeBack.clear();
            for (int i = 0; i < index; i++) {
                requests[i] = REQUEST_EMPTY;
            }
            index = 0;

            BatchData<unsigned long long> *pQueueData;

            auto timestampWriteToBatch = std::chrono::high_resolution_clock::now();

            // holdonto is leftover stuff from our last batch which won't fit into that batch. We instead roll it over
            // into the next batch.
            if (holdonto) {
                //std::cerr << "Hold onto set " << tid << std::endl;
                writeBack.push_back({index, holdonto});

                for (int i = 0; i < holdonto->idx; i++) {
                    keys[index + i] = holdonto->keys[i];
                    values[index + i] = holdonto->values[i];
                    requests[index + i] = holdonto->requests[i];
                    hashes[index + i] = holdonto->hashes[i];
                }
                index += holdonto->idx;
                sampleTime = holdonto->start;
                holdonto = nullptr;
                sampleTimeSet = true;
            }

            int attempts = 0;

            // Get stuff from the queue and add it to our BatchBuffer until the buffer is full, or we fail to
            // get anything from the queue after MAX_ATTEMPTS.
            while (attempts < MAX_ATTEMPTS && index < THREADS_PER_BLOCK * BLOCKS) {
                // Try to get some BatchData from the workqueue for thread.
                if (this->gpu_qs[gpu].try_pop(pQueueData)) {
                    load--;
                    //std::cerr << "Got a batch on handler thread " << tid << "\n";
                    if (pQueueData->idx + index > THREADS_PER_BLOCK * BLOCKS) {
                        //std::cerr << "Cannot add any more to batch " << tid << "\n";
                        holdonto = pQueueData;
                        break;
                    }
                    for (int i = 0; i < pQueueData->idx; i++) {
                        keys[index + i] = pQueueData->keys[i];
                        values[index + i] = pQueueData->values[i];
                        assert(pQueueData->requests[i] != REQUEST_INSERT || pQueueData->values[i]->size > 0);
                        requests[index + i] = pQueueData->requests[i];
                        hashes[index + i] = pQueueData->hashes[i];
                    }
                    writeBack.push_back({index, pQueueData});
                    index += pQueueData->idx;
                    if (!sampleTimeSet) {
                        sampleTime = pQueueData->start;
                        sampleTimeSet = true;
                    }

                    if (pQueueData->flush) {
                        break;
                    }
                } else {
                    attempts++;
                }
            }
            sampleTimeSet = false;

            // If we get to this point we have a reasonably full batch which we're now going to execute on the GPU.
            if (index > 0) {

                //std::cerr << "Batching " << tid << "\n";

                auto timestampStartBatch = std::chrono::high_resolution_clock::now();

                cudaEvent_t start, stop;

                gpuErrchk(cudaEventCreate(&start));
                gpuErrchk(cudaEventCreate(&stop));

                // Currently I include this translation layer as part of the batching. Maybe I shouldn't? It will include lots of moving memory to the GPU anyways.
                gpuErrchk(cudaEventRecord(start, stream));

                float t;

                // TODO: Will need a way to pass through the streamId. Setting to zero is fine for now for only one GPU.
                btree->diyConcurrentOperations(keys, values, reinterpret_cast<OperationT *>(requests), index);

                // FIXME: This batching metric will also include lots of moving memory to the GPU. Not exactly useful.
                //  compared to slab which does the memory movement before it starts the timer.
                gpuErrchk(cudaEventRecord(stop, stream));
                gpuErrchk(cudaStreamSynchronize(stream));

                auto timestampWriteBack = std::chrono::high_resolution_clock::now();
                gpuErrchk(cudaEventElapsedTime(&t, start, stop));
                gpuErrchk(cudaEventDestroy(start));
                gpuErrchk(cudaEventDestroy(stop));

                // Handle writing results back to the CPU
                int timesGoingToCache = 0;
                for (auto &[wbIndex, pBatchData] : writeBack) {
                    // Guessing idx is how many entries are in the BatchData
                    for (int i = 0; i < pBatchData->idx; ++i) {
                        if (pBatchData->handleInCache[i]) {
                            timesGoingToCache++;

                            auto value = _cache->missCallback(
                                    pBatchData->keys[i], values[wbIndex + i], pBatchData->hashes[i],
                                    *(this->model));
                            pBatchData->resBuf->send(Response(pBatchData->requestID[i], value, false));

                        } else {
                            data_t* value;
                            if (requests[wbIndex + i] == REQUEST_REMOVE) {
                                value = values[wbIndex + i];

                            } else if (requests[wbIndex + i] == REQUEST_GET) {
                                V cpy = nullptr;
                                if (values[wbIndex + i]) {
                                    cpy = new data_t(values[wbIndex + i]->size);
                                    memcpy(cpy->data, values[wbIndex + i]->data, cpy->size);
                                }
                                value = cpy;
                            } else {
                                value = nullptr;
                            }
                            pBatchData->resBuf->send(Response(pBatchData->requestID[i], value, false));
                        }
                    }
                    delete pBatchData;
                }

                // Count the OPS and handle other performance metrics
                mops[gpu].push_back({sampleTime,
                                            /*timestampEnd = */
                                     std::chrono::high_resolution_clock::now(),
                                            /*timestampWriteBack = */ timestampWriteBack,
                                            /*timestampStartBatch = */timestampStartBatch,
                                            /*timestampDequeueToBatch = */timestampWriteToBatch,
                                            /*duration*/t,
                                            /*size = */index,
                                            /*timesGoingToCache=*/ timesGoingToCache});

                ops += index;
                //std::cerr << "Batched " << tid << "\n";

            }
        }
        if (stream != cudaStreamDefault) gpuErrchk(cudaStreamDestroy(stream));
    };

    ~BTrees() {
        std::cerr << "BTrees deleted\n";
        done = true;
        for (auto &t : threads) {
            if (t.joinable())
                t.join();
        }
        delete[] gpu_qs;
        delete[] mops;
    }

    inline void clearMops() {
        for (int i = 0; i < numslabs; i++) {
            mops[i].clear();
        }
        ops = 0;
    }

    inline size_t getOps() {
        return ops;
    }

    inline void batch(BatchData<unsigned long long> *b, int partition) {
        gpu_qs[partition].push(b);
    }

    inline void increaseLoad() {
        load++;
    }

    inline size_t getLoad() {
        return load.load();
    }

    inline tbb::concurrent_vector<StatData> *getMops() {
        return mops;
    }

    inline int getNumslabs() {
        return numslabs;
    }

private:
    std::atomic_int load;
    /// Work queue for the threads to take from
    q_t *gpu_qs;
    int numslabs;
    std::vector<std::thread> threads;
    std::atomic_bool done;
    /// Holds timing data
    tbb::concurrent_vector<StatData> *mops;
    std::shared_ptr<typename Cache::type> _cache;
    std::atomic_size_t ops;
    std::shared_ptr<M> model;
};

#endif //KVCG_BTREES_HH
