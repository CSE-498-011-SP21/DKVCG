#include <unistd.h>
#include <map>
#include "helper.cuh"
#include <networklayer/connectionless.hh>
#include <RemoteCommunication.hh>
#include <cmath>
#include <string>

#include <faulttolerance/fault_tolerance.h>
namespace ft = cse498::faulttolerance;
int LOG_LEVEL = WARNING;

void sendBatchAndRecvResponse(cse498::Connection *client,
                              std::vector<RequestWrapper<unsigned long long, data_t *>> &clientBatch,
                              cse498::unique_buf &buf) {
    std::vector<char> serializedData;
    serializedData.reserve(4096);

    size_t batchsize = clientBatch.size();

    buf.cpyTo((const char *) &batchsize, sizeof(size_t));
    client->send(buf, sizeof(size_t));

    for (auto &r : clientBatch) {
        std::vector<char> v = serialize(r);

        if (v.size() + sizeof(size_t) + serializedData.size() >= 4096) {
            size_t size = serializedData.size();
            buf.cpyTo((char *) &size, sizeof(size_t));
            client->send(buf, sizeof(size_t));
            buf.cpyTo(serializedData.data(), serializedData.size());
            client->send(buf, serializedData.size());
            serializedData.clear();
        }

        serializedData.insert(serializedData.end(), v.begin(), v.end());

    }

    if (!serializedData.empty()) {
        size_t size = serializedData.size();
        buf.cpyTo((char *) &size, sizeof(size_t));
        client->send(buf, sizeof(size_t));
        buf.cpyTo(serializedData.data(), serializedData.size());
        client->send(buf, serializedData.size());
        serializedData.clear();
    }

    auto start = std::chrono::high_resolution_clock::now();
    for (int i = 0; i < batchsize; i++) {
        client->recv(buf, 4096);
    }
    auto end = std::chrono::high_resolution_clock::now();

    std::cout << 512 / std::chrono::duration<double>(end - start).count() << " Ops" << std::endl;
}

void endConnection(cse498::Connection *client, cse498::unique_buf &buf) {
    size_t batchsize = 0;
    buf.cpyTo((const char *) &batchsize, sizeof(size_t));
    client->send(buf, sizeof(size_t));
}

int main(int argc, char **argv) {
    std::string cfgFile;
    bool ftEnabled = true;
    ft::Client* ftClient = new ft::Client();

    char c;
    while ((c = getopt(argc, argv, "vf:")) != -1) {
        switch (c) {
            case 'v':
                LOG_LEVEL++;
                break;
            case 'f':
                cfgFile = optarg;
                // optarg is the file
                break;
        }
    }

    int ftstatus = ftClient->initialize(cfgFile);
    if (ftstatus) {
      if (ftstatus == KVCG_EBADCONFIG) {
          LOG(WARNING) << "Fault-Tolerance disabled";
          ftEnabled = false;
      } else {
          // fatal
          return 1;
      }
    }

    if (ftEnabled) {
        std::map<ft::Shard*, std::vector<RequestWrapper<unsigned long long, data_t *>>*> batches;
        for (int i = 0; i < 512; i++) {
            ft::Shard* shard = ftClient->getShard((unsigned long long) (i + 1));

            if (batches.find(shard) == batches.end()) {
                batches.insert({shard, new std::vector<RequestWrapper<unsigned long long, data_t *>>});
            }
            batches.find(shard)->second->push_back({(unsigned long long) (i + 1), 0, new data_t(32), REQUEST_INSERT});
        }

        for (auto it = batches.begin(); it != batches.end(); ++it) {
            auto primary = it->first->getPrimary();

            if (primary == nullptr) {
                it->first->discoverPrimary();
            }

            primary = it->first->getPrimary();
            if (primary == nullptr) {
                LOG(ERROR) << "Client connection not initialized";
                it->first->discoverPrimary();
                return 1;
            }

            auto client = new cse498::Connection(primary->getAddr().c_str(), false, 8081);
            client->connect();

            cse498::unique_buf* buf = new cse498::unique_buf();
            uint64_t key = 1;
            client->register_mr(*buf, FI_READ | FI_WRITE | FI_SEND | FI_RECV, key);

            sendBatchAndRecvResponse(client, *it->second, *buf);
            endConnection(client, *buf);
        }
    }
    else {
        auto client = new cse498::Connection("127.0.0.1", false, 8081);
        client->connect();

        cse498::unique_buf buf;
        uint64_t key = 1;
        client->register_mr(buf, FI_READ | FI_WRITE | FI_SEND | FI_RECV, key);

        std::vector<RequestWrapper<unsigned long long, data_t *>> clientBatch;
        for (int i = 0; i < 512; i++) {
            clientBatch.push_back({(unsigned long long) (i + 1), 0, new data_t(32), REQUEST_INSERT});
        }

        sendBatchAndRecvResponse(client, clientBatch, buf);
        endConnection(client, buf);

        delete client;
    }

    return 0;
}

void usage(char *command) {
    using namespace std;
    cout << command << " [-f <config file>]" << std::endl;
}
