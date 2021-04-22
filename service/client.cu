#include <unistd.h>
#include <sstream>
#include <map>
#include "helper.cuh"
#include <networklayer/connectionless.hh>
#include <RemoteCommunication.hh>
#include <cmath>
#include <string>

#include <boost/property_tree/ptree.hpp>
#include <boost/property_tree/json_parser.hpp>

#include <data_t.hh>
#include <RequestTypes.hh>
#include <RequestWrapper.hh>

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
            if (!client->try_wait_for_sends()) {
                return false;
            }
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
        if (!client->try_wait_for_sends()) {
            return false;
        }
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
        LOG(DEBUG3) << "Recieved: " << buf.get();
    }
    auto end = std::chrono::high_resolution_clock::now();

    std::cout << batchsize / std::chrono::duration<double>(end - start).count() << " Ops" << std::endl;

    return true;
}

void endConnection(cse498::Connection *client, cse498::unique_buf &buf) {
    size_t batchsize = 0;
    buf.cpyTo((const char *) &batchsize, sizeof(size_t));
    client->send(buf, sizeof(size_t));
}

std::vector<RequestWrapper<unsigned long long, data_t *>> openTestFile(std::string file) {
    std::vector<RequestWrapper<unsigned long long, data_t *>> requestList;
    std::fstream fin;
    // TODO: deal w failure if unable to open
    fin.open(file, std::ios::in);

    std::string line;
    int reqInt;
    std::string key_str;
    unsigned long long key;
    unsigned long long endRange;
    std::string reqType;
    std::string value;

    LOG(DEBUG4) << "Started reading data file: " << file;
    
    while(!fin.eof()) {
        getline(fin, line);
        if (line.empty()) break;

        std::stringstream s(line);

        LOG(DEBUG4) << "Read Line: " << line;

        getline(s, key_str, ',');
    
        if (key_str.empty()) break;
        key = std::stoull(key_str, nullptr, 10);
        
        LOG(DEBUG4) << "Key: " << key_str;

        getline(s, key_str, ',');
    
        if (key_str.empty()) break;
        endRange = std::stoull(key_str, nullptr, 10);
        
        LOG(DEBUG4) << "endRange: " << key_str;

        getline(s, reqType, ',');;
        
        LOG(DEBUG4) << "ReqType: " << reqType;

        if (reqType.compare("put") == 0) {
            reqInt = REQUEST_INSERT;
        }
        else if (reqType.compare("get") == 0) {
            reqInt = REQUEST_GET;
        }
        else if (reqType.compare("delete") == 0) {
            reqInt = REQUEST_REMOVE;
        }
        else if (reqType.compare("range") == 0) {
            reqInt = REQUEST_RQ;
        }
        
        getline(s, value);
        LOG(DEBUG4) << "Value: " << value;

        data_t* value_data = new data_t(value.size());
        strcpy(value_data->data, value.c_str());

        requestList.push_back({key, endRange, value_data, reqInt});
    }

    fin.close();

    return requestList;
}

std::map<ft::Shard*, std::vector<RequestWrapper<unsigned long long, data_t *>>*> sortRequestsToShards(std::vector<RequestWrapper<unsigned long long, data_t *>> requestList, ft::Client* ftClient) {
    std::map<ft::Shard*, std::vector<RequestWrapper<unsigned long long, data_t *>>*> batches;

    for (auto request : requestList) {
        ft::Shard* shard = ftClient->getShard(request.key);

        if (batches.find(shard) == batches.end()) {
            batches.insert({shard, new std::vector<RequestWrapper<unsigned long long, data_t *>>});
        }

        batches.find(shard)->second->push_back(request);
    }

    return batches;
}

int main(int argc, char **argv) {
    LOG(DEBUG3) << "Started Client";
    std::string cfgFile;
    std::string testFile = "";
    bool ftEnabled = true;
    ft::Client* ftClient = new ft::Client();
    int port = 8080;
    pt::ptree root;

    char c;
    while ((c = getopt(argc, argv, "vf:t:")) != -1) {
        switch (c) {
            case 'v':
                LOG_LEVEL++;
                break;
            case 'f':
                cfgFile = optarg;
                pt::read_json(cfgFile, root);
                port = root.get<int>("port", port);
                // optarg is the file
                break;
            case 't':
                testFile = optarg;
                // optarg is csv file containing test data
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

    std::vector<RequestWrapper<unsigned long long, data_t *>> clientBatch;
    if (testFile.compare("") == 0) {
        for (int i = 0; i < 512; i++) {
            clientBatch.push_back({(unsigned long long) (i + 1), 0, new data_t(32), REQUEST_INSERT});
        }
    }
    else {
        clientBatch = openTestFile(testFile);
    }

    if (ftEnabled) {
        std::map<ft::Shard*, std::vector<RequestWrapper<unsigned long long, data_t *>>*> batches = sortRequestsToShards(clientBatch, ftClient);

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

            auto client = new cse498::Connection(primary->getAddr().c_str(), false, port);
            client->connect();

            cse498::unique_buf* buf = new cse498::unique_buf();
            uint64_t key = 1;
            client->register_mr(*buf, FI_READ | FI_WRITE | FI_SEND | FI_RECV, key);

            if (!sendBatchAndRecvResponse(client, *it->second, *buf)) {
                it->first->discoverPrimary();
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

        sendBatchAndRecvResponse(client, clientBatch, buf);
        endConnection(client, buf);

        delete client;
    }

    return 0;
}

void usage(char *command) {
    using namespace std;
    cout << command << " [-f <config file>] [-t <test csv file>]" << std::endl;
}
