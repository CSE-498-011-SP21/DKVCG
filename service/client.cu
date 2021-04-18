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

bool sendBatchAndRecvResponse(cse498::Connection *client,
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
            client->async_send(buf, sizeof(size_t));
            buf.cpyTo(serializedData.data(), serializedData.size());
            client->async_send(buf, serializedData.size());
            serializedData.clear();
            if (!client->try_wait_for_sends()) {
                return false;
            }
        }

        serializedData.insert(serializedData.end(), v.begin(), v.end());

    }

    if (!serializedData.empty()) {
        size_t size = serializedData.size();
        buf.cpyTo((char *) &size, sizeof(size_t));
        client->async_send(buf, sizeof(size_t));
        buf.cpyTo(serializedData.data(), serializedData.size());
        client->async_send(buf, serializedData.size());
        serializedData.clear();
        if (!client->try_wait_for_sends()) {
            return false;
        }
    }

    auto start = std::chrono::high_resolution_clock::now();
    for (int i = 0; i < batchsize; i++) {
        client->recv(buf, 4096);
    }
    auto end = std::chrono::high_resolution_clock::now();

    std::cout << 512 / std::chrono::duration<double>(end - start).count() << " Ops" << std::endl;

    return true;
}

void endConnection(cse498::Connection *client, cse498::unique_buf &buf) {
    size_t batchsize = 0;
    buf.cpyTo((const char *) &batchsize, sizeof(size_t));
    client->send(buf, sizeof(size_t));
}

std::map<ft::Shard*, std::vector<RequestWrapper<unsigned long long, data_t *>>*> openTestFile(std::string file, ft::Client* ftClient) {
    std::map<ft::Shard*, std::vector<RequestWrapper<unsigned long long, data_t *>>*> batches;
    fstream fin;
    // TODO: deal w failure if unable to open
    fin.open(file, ios::in);

    int reqInt;
    unsigned long long key;
    data_t value;
    
    while(getline(file, key, ',')) {
        getline(file, value, ',');
        getline(file, reqInt);
        
        ft::Shard* shard = ftClient->getShard((unsigned long long) key);

        if (batches.find(shard) == batches.end()) {
            batches.insert({shard, new std::vector<RequestWrapper<unsigned long long, data_t *>>});
        }
        batches.find(shard)->second->push_back({key, 0, value, reqInt});
    }

    return batches;
}

int main(int argc, char **argv) {
    std::string cfgFile;
    std::string testFile = nullptr;
    bool ftEnabled = true;
    ft::Client* ftClient = new ft::Client();

    char c;
    while ((c = getopt(argc, argv, "vft:")) != -1) {
        switch (c) {
            case 'v':
                LOG_LEVEL++;
                break;
            case 'f':
                cfgFile = optarg;
                // optarg is the file
                break;
            case 't':
                testFile = testData;
                // testData is csv file containing test data
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
        if (testFile == nullptr) {
            for (int i = 0; i < 512; i++) {
                ft::Shard* shard = ftClient->getShard((unsigned long long) (i + 1));

                if (batches.find(shard) == batches.end()) {
                    batches.insert({shard, new std::vector<RequestWrapper<unsigned long long, data_t *>>});
                }
                batches.find(shard)->second->push_back({(unsigned long long) (i + 1), 0, new data_t(32), REQUEST_INSERT});
            }
        } else {
            batches = openTestFile(testFile, ftClient);
        }
        

        for (auto it = batches.begin(); it != batches.end(); ++it) {
            auto client = it->first->getPrimary()->primary_conn;
            // TODO: would line below fail if no longer primary..? or not till below in sendBatchAndRecvResponse
            client->connect();

            cse498::unique_buf* buf = new cse498::unique_buf();
            uint64_t key = 1;
            client->register_mr(*buf, FI_READ | FI_WRITE | FI_SEND | FI_RECV, key);

            if (!sendBatchAndRecvResponse(client, *it->second, *buf)) {
                it->first->discoverPrimary();
                client = it->first->getPrimary()->primary_conn;
            }
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
