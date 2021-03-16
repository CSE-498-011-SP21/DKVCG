//
// Created by depaulsmiller on 1/15/21.
//

#include <unistd.h>
#include "helper.cuh"
#include <algorithm>
#include <boost/property_tree/ptree.hpp>
#include <boost/property_tree/json_parser.hpp>
#include <dlfcn.h>

namespace pt = boost::property_tree;
using BatchWrapper = std::vector<RequestWrapper<unsigned long long, data_t *>>;
//#ifdef MODEL_CHANGE
using Model = kvgpu::AnalyticalModel<unsigned long long>;
//#else
//using Model = kvgpu::SimplModel<unsigned long long>;
//#endif
using RB = std::shared_ptr<Communication>;

int totalBatches = 10000;
int BATCHSIZE = 512;
int NUM_THREADS = 12;//std::thread::hardware_concurrency() - 10;

void usage(char *command);

struct ServerConf {
    int threads;
    int cpu_threads;

    int gpus;
    int streams;
    std::string modelFile;
    bool train;
    int size;
    int batchSize;
    bool cache;

    ServerConf() {
        batchSize = BATCHSIZE;
        modelFile = "";
        cpu_threads = NUM_THREADS;
        threads = 2;//1;//4;
        gpus = 1;
        streams = 10;//10;
        size = 1000000;
        train = false;
        cache = true;
    }

    explicit ServerConf(const std::string &filename) {
        pt::ptree root;
        pt::read_json(filename, root);
        cpu_threads = root.get<int>("cpu_threads", NUM_THREADS);
        threads = root.get<int>("threads", 4);
        streams = root.get<int>("streams", 2);
        gpus = root.get<int>("gpus", 2);
        modelFile = root.get<std::string>("modelFile", "");
        train = root.get<bool>("train", false);
        size = root.get<int>("size", 1000000);
        batchSize = root.get<int>("batchSize", BATCHSIZE);
        cache = root.get<bool>("cache", true);
    }

    void persist(const std::string &filename) const {
        pt::ptree root;
        root.put("threads", threads);
        root.put("streams", streams);
        root.put("gpus", gpus);
        root.put("modelFile", modelFile);
        root.put("train", train);
        root.put("size", size);
        root.put("batchSize", batchSize);
        root.put("cache", cache);
        pt::write_json(filename, root);
    }

    ~ServerConf() = default;

};

int main(int argc, char **argv) {

    ServerConf sconf;

    bool workloadFilenameSet = false;
    std::string workloadFilename;
#ifdef MODEL_CHANGE
    std::string dllib = "./libzipfianWorkloadSwitch.so";
#else
    std::string dllib = "./libzipfianWorkload.so";
#endif
    char c;
    while ((c = getopt(argc, argv, "f:w:l:")) != -1) {
        switch (c) {
            case 'f':
                sconf = ServerConf(std::string(optarg));
                // optarg is the file
                break;
            case 'w':
                workloadFilenameSet = true;
                workloadFilename = optarg;
                break;
            case 'l':
                dllib = optarg;
                break;
            default:
            case '?':
                usage(argv[0]);
                return 1;
        }
    }

    void (*initWorkload)() = nullptr;
    void (*initWorkloadFile)(std::string) = nullptr;
    BatchWrapper (*generateWorkloadBatch)(unsigned int *, unsigned) = nullptr;
    int (*getBatchesToRun)() = nullptr;
    std::vector<BatchWrapper> (*getPopulationBatches)(unsigned int *, unsigned) = nullptr;
    auto handler = dlopen(dllib.c_str(), RTLD_LAZY);
    if (!handler) {
        std::cerr << dlerror() << std::endl;
        return 1;
    }
    initWorkload = (void (*)()) dlsym(handler, "initWorkload");
    initWorkloadFile = (void (*)(std::string)) dlsym(handler, "initWorkloadFile");
    generateWorkloadBatch = (BatchWrapper(*)(unsigned *, unsigned)) dlsym(handler, "generateWorkloadBatch");
    getBatchesToRun = (int (*)()) dlsym(handler, "getBatchesToRun");
    getPopulationBatches = (std::vector<BatchWrapper> (*)(unsigned int *, unsigned)) dlsym(handler,
                                                                                           "getPopulationBatches");

#ifdef MODEL_CHANGE
    auto workloadSwitch = (void (*)()) dlsym(handler, "changeWorkload");
#endif

    if (workloadFilenameSet) {
        initWorkloadFile(workloadFilename);
    } else {
        initWorkload();
    }

    totalBatches = getBatchesToRun();

    std::vector<PartitionedSlabUnifiedConfig> conf;
    for (int i = 0; i < sconf.gpus; i++) {
        for (int j = 0; j < sconf.streams; j++) {
            gpuErrchk(cudaSetDevice(i));
            cudaStream_t stream = cudaStreamDefault;
            if (j != 0) {
                gpuErrchk(cudaStreamCreate(&stream));
            }
            conf.push_back({sconf.size, i, stream});
        }
    }

    std::unique_ptr<KVStoreCtx<Model>> ctx = nullptr;
    if (sconf.modelFile != "") {
        ctx = std::make_unique<KVStoreCtx<Model>>(conf, sconf.cpu_threads, sconf.modelFile);
    } else {
//#ifdef MODEL_CHANGE
        unsigned tseed = time(nullptr);
        std::vector<std::pair<unsigned long long, unsigned>> trainVec;
        std::hash<unsigned long long> hfn{};
        for (int i = 0; i < 10000; i++) {
            BatchWrapper b = generateWorkloadBatch(&tseed, sconf.batchSize);
            for (auto &elm : b) {
                trainVec.push_back({elm.key, hfn(elm.key)});
            }
        }

        Model m;
        m.train(trainVec);
        m.persist("./temp.json");
#ifdef MODEL_CHANGE
        workloadSwitch();
#endif
        ctx = std::make_unique<KVStoreCtx<Model>>(conf, sconf.cpu_threads, m);
//#else
//        ctx = std::make_unique<KVStoreCtx<unsigned long long, data_t, Model>>(conf, sconf.cpu_threads);
//#endif
    }

    GeneralClient<Model> *client = nullptr;
    if (sconf.cache) {
        if (sconf.gpus == 0) {
            client = new JustCacheKVStoreClient<Model>(*ctx);
        } else {
            client = new KVStoreClient<Model>(*ctx);
        }
    } else {
        client = new NoCacheKVStoreClient<Model>(*ctx);
    }

    unsigned popSeed = time(nullptr);
    auto pop = getPopulationBatches(&popSeed, BATCHSIZE);

    for (auto &b : pop) {
        bool retry;
        int size = b.size();
        do {
            retry = false;
            loadBalanceSet = true;

            auto rb = std::make_shared<LocalCommunication>(sconf.batchSize);
            auto start = std::chrono::high_resolution_clock::now();
            client->batch(b, rb, start);

            int count = 0;
            do {
                Response response;
                if (rb->try_recv(response)) {
                    count++;
                    if (response.retry) {
                        retry = true;
                    }
                }
            } while (count < size);
        } while (retry);
    }

    std::cerr << "Populated" << std::endl;

    client->resetStats();

    std::vector<std::thread> threads;

    auto *q = new tbb::concurrent_queue<std::pair<BatchWrapper, RB>>[sconf.threads];

    std::atomic_bool reclaim{false};

    std::atomic_bool changing{false};

    auto *block = new block_t(sconf.threads);

    for (int i = 0; i < sconf.threads; ++i) {
        threads.push_back(std::thread([&client, &reclaim, &q, &changing, &block, sconf](int tid) {

            init_loadbalance(sconf.cpu_threads);

            std::shared_ptr<Communication> lastResBuf = nullptr;

            while (!reclaim) {
                std::pair<BatchWrapper, RB> p;

                if (changing) {
                    block->wait();
                    while (changing) {
                        if (q[tid].try_pop(p)) {
                            auto start = std::chrono::high_resolution_clock::now();
                            client->batch_drop_modifications(p.first, p.second, start);
                        }
                    }
                }

                if (q[tid].try_pop(p)) {
                    auto start = std::chrono::high_resolution_clock::now();
                    lastResBuf = p.second;
                    client->batch(p.first, p.second, start);
                }
            }

            std::pair<BatchWrapper, RB> p;
            while (q[tid].try_pop(p)) {
                auto start = std::chrono::high_resolution_clock::now();
                lastResBuf = p.second;
                client->batch(p.first, p.second, start);
            }

            int count = 0;
            do {
                Response response;
                if (lastResBuf->try_recv(response)) {
                    count++;
                }
            } while (count < sconf.batchSize);

        }, i));
    }
    auto startTime = std::chrono::high_resolution_clock::now();

    std::vector<std::thread> threads2;
    int clients = 8;

#ifdef MODEL_CHANGE
    std::atomic_bool finishBatching;
    finishBatching = false;

    auto fn = [&finishBatching, clients, &q, &sconf, generateWorkloadBatch, &changing, &block, &client](int tid) {
        unsigned tseed = time(nullptr);
        int i = 0;
        while (!finishBatching) {

            /*if (tid == 0 && i == totalBatches / clients / 10) {
                std::cerr << "Changing\n";
                auto tmp = Model(18000);
                double time;
                client->change_model(changing, tmp, block, time);
                std::cerr << "Changed " << time * 1e3 << "\n";
            }*/

            auto rb = std::make_shared<ResultsBuffers<data_t>>(sconf.batchSize);

            std::pair<BatchWrapper, RB> p = {
                    generateWorkloadBatch(&tseed, sconf.batchSize),
                    std::move(rb)};
            q[(tid + i) % sconf.threads].push(std::move(p));
            i++;
        }
    };
#else
    auto fn = [clients, &q, &sconf, generateWorkloadBatch, &changing, &block, &client](int tid) {
        unsigned tseed = time(nullptr);
        for (int i = 0; i < totalBatches / clients; i++) {

            /*if (tid == 0 && i == totalBatches / clients / 10) {
                std::cerr << "Changing\n";
                auto tmp = Model(18000);
                double time;
                client->change_model(changing, tmp, block, time);
                std::cerr << "Changed " << time * 1e3 << "\n";
            }*/

            auto rb = std::make_shared<LocalCommunication>(sconf.batchSize);

            std::pair<BatchWrapper, RB> p = {
                    generateWorkloadBatch(&tseed, sconf.batchSize),
                    std::move(rb)};
            q[(tid + i) % sconf.threads].push(std::move(p));

        }
        if (tid == 0) {
            for (int i = 0; i < totalBatches - (totalBatches / clients) * clients; i++) {

                /*if (tid == 0 && i == totalBatches / clients / 10) {
                    std::cerr << "Changing\n";
                    auto tmp = kvgpu::SimplModel<unsigned>(18000);
                    changing = true;
                    client->change_model(tmp, block);
                    changing = false;
                    std::cerr << "Changed\n";
                }*/

                auto rb = std::make_shared<LocalCommunication>(sconf.batchSize);

                std::pair<BatchWrapper, RB> p = {
                        generateWorkloadBatch(&tseed, sconf.batchSize),
                        std::move(rb)};
                q[(tid + i) % sconf.threads].push(std::move(p));

            }
        }
    };
#endif
    for (int j = 0; j < clients; j++) {
        threads2.push_back(std::thread(fn, j));
    }

#ifdef MODEL_CHANGE
    std::cerr << "Sleep" << std::endl;
    sleep(1);
    //workloadSwitch();
    //sleep(1);
    std::vector<std::pair<unsigned long long, unsigned>> trainVec;
    unsigned threadSeeed = time(nullptr);
    for (int i = 0; i < 10000; i++) {
        BatchWrapper b = generateWorkloadBatch(&threadSeeed, sconf.batchSize);
        std::hash<unsigned long long> hfn{};
        for (auto &elm : b) {
            trainVec.push_back({elm.key, hfn(elm.key)});
        }
    }

    Model m;
    m.train(trainVec);
    m.persist("temp2.json");
    std::cerr << "Changing\n";
    double modelchange_time;
    auto changeTime = std::chrono::high_resolution_clock::now();
    client->change_model(changing, m, block, modelchange_time);
    std::cerr << "Changed " << modelchange_time * 1e3 << "\n";

    sleep(5);
    finishBatching = true;
#endif

    for (auto &t : threads2) {
        t.join();
    }
    auto endTimeArrival = std::chrono::high_resolution_clock::now();


    reclaim = true;


    std::cerr << "Awake and joining\n";
    for (auto &t : threads) {
        t.join();
    }
    auto times = client->getCacheTimes();

    auto endTime = std::chrono::high_resolution_clock::now();
    size_t ops = client->getOps();

    std::sort(times.begin(), times.end(),
              [](const std::pair<std::chrono::high_resolution_clock::time_point, std::vector<std::chrono::high_resolution_clock::time_point>> &lhs,
                 const std::pair<std::chrono::high_resolution_clock::time_point, std::vector<std::chrono::high_resolution_clock::time_point>> &rhs) {
                  return lhs.first < rhs.first;
              });

    std::vector<std::pair<std::chrono::high_resolution_clock::time_point, std::vector<double>>> times2;

    for (auto &t : times) {
        std::vector<double> tmp;
        for (auto &t2 : t.second) {
            tmp.push_back(std::chrono::duration<double>(t2 - t.first).count());
        }
        times2.push_back({t.first, tmp});
    }

    std::chrono::duration<double> dur = endTime - startTime;
    std::chrono::duration<double> durArr = endTimeArrival - startTime;
    if (!times.empty()) {
        if (sconf.cache) {
            auto s = client->getStart();
            std::cout << "TABLE: Latency of Hot Storage" << std::endl;
            std::cout << "Timestamp\tAvg Latency\tMin Latency\tMax Latency\tOps" << std::endl;
            for (auto &t : times2) {
                if (!t.second.empty()) {
                    double avg = 0.0;
                    std::for_each(t.second.begin(), t.second.end(), [&avg](double d) {
                        avg += d;
                    });

                    avg /= t.second.size();

                    std::cout << std::chrono::duration<double>(t.first - s).count() << "\t" << avg * 1e3 << "\t"
                              << t.second[0] * 1e3 << "\t" << t.second[t.second.size() - 1] * 1e3 << "\t" <<
                              t.second.size() << std::endl;
                }
            }

            //delete barrier;

            std::cout << std::endl;

            std::cout << "TABLE: Hot Storage Latencies" << std::endl;
            std::cout << "Latency" << std::endl;
            for (auto &t : times2) {
                for (auto &t2 : t.second) {
                    std::cout << t2 * 1e3 << std::endl;
                }
            }

            std::cout << std::endl;
        }

        client->stat();

        std::cerr << "Arrival Rate (Mops) " << (sconf.batchSize * times.size()) / durArr.count() / 1e6 << std::endl;
        std::cerr << "Throughput (Mops) " << ((double) ops + client->getHits()) / dur.count() / 1e6 << std::endl;

        if (sconf.cache) {
            std::cerr << "Hit Rate\tHits" << std::endl;
            std::cerr << client->hitRate() << "\t" << client->getHits() << std::endl;
            std::cerr << std::endl;
        }

        std::cout << "TABLE: Throughput" << std::endl;
        std::cout << "Throughput" << std::endl;
        std::cout << ((double) ops + client->getHits()) / dur.count() / 1e6 << std::endl;

#if MODEL_CHANGE
        std::cout << "TABLE: Model Change" << std::endl;
        std::cout << "Latency\tStart" << std::endl;
        std::cout << modelchange_time * 1e3 << "\t" << std::chrono::duration<double>(changeTime - client->getStart()).count() << std::endl;
#endif
    }
    delete client;
    delete block;
    dlclose(handler);
    return 0;
}

void usage(char *command) {
    using namespace std;
    cout << command << " [-f <config file>]" << std::endl;
}
