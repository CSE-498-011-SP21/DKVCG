#include <unistd.h>
#include "helper.cuh"
#include <algorithm>
#include <boost/property_tree/ptree.hpp>
#include <boost/property_tree/json_parser.hpp>
#include <RemoteCommunication.hh>

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

int LOG_LEVEL = WARNING;

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

    char c;
    while ((c = getopt(argc, argv, "f:")) != -1) {
        switch (c) {
            case 'f':
                sconf = ServerConf(std::string(optarg));
                // optarg is the file
                break;
            default:
            case '?':
                usage(argv[0]);
                return 1;
        }
    }

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
        ctx = std::make_unique<KVStoreCtx<Model>>(conf, sconf.cpu_threads);
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

    auto server = new cse498::Connection("127.0.0.1", true, 8080);
    loadBalanceSet = true;
    server->connect();


    uint64_t key = 1;
    auto* buf = new cse498::unique_buf();
    server->register_mr(*buf, FI_READ | FI_WRITE | FI_SEND | FI_RECV, key);

    std::vector<RequestWrapper<unsigned long long int, data_t *>> clientBatch;

    while (true) {

        server->recv(*buf, sizeof(size_t));
        size_t batchsize = *(size_t *) buf->get();
        if (batchsize == 0) {
            break;
        }

        clientBatch.reserve(batchsize);

        while (clientBatch.size() != batchsize) {
            server->recv(*buf, sizeof(size_t));
            size_t incomingBytes = *(size_t *) buf->get();
            server->recv(*buf, incomingBytes);

            size_t offset = 0;
            while (offset < incomingBytes) {
                size_t amountConsumed = 0;
                auto r = deserialize2<RequestWrapper<unsigned long long, data_t *>>(
                        std::vector<char>(buf->get() + offset, buf->get() + incomingBytes), amountConsumed);
                clientBatch.push_back(r);
                offset += amountConsumed;
            }
        }

        auto start = std::chrono::high_resolution_clock::now();
        std::shared_ptr<Communication> comm = std::make_shared<RemoteCommunication>(server, buf);
        client->batch(clientBatch, comm, start);

        std::cerr << "Ran batch\n";
    }

    delete client;
    delete buf;
    //delete server;
    return 0;
}

void usage(char *command) {
    using namespace std;
    cout << command << " [-f <config file>]" << std::endl;
}
