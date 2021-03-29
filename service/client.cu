#include <unistd.h>
#include "helper.cuh"
#include <networklayer/connectionless.hh>
#include <RemoteCommunication.hh>
#include <cmath>

int LOG_LEVEL = TRACE;

int main(int argc, char **argv) {

    auto client = new cse498::ConnectionlessClient("127.0.0.1", 8080);

    char *buf = new char[4096];
    cse498::mr_t mr;

    client->registerMR(buf, 4096, mr);

    client->connect(buf, 4096);

    std::vector<RequestWrapper<unsigned long long, data_t *>> clientBatch;
    for (int i = 0; i < 512; i++) {
        clientBatch.push_back({(unsigned long long) (i + 1), new data_t(32), REQUEST_INSERT});
    }

    std::vector<char> serializedData;
    serializedData.reserve(4096);

    for (auto &r : clientBatch) {
        std::vector<char> v = serialize(r);

        if (v.size() + sizeof(size_t) + serializedData.size() >= 4096) {
            size_t size = serializedData.size();
            memcpy(buf, &size, sizeof(size_t));
            client->send(buf, sizeof(size_t));
            memcpy(buf, serializedData.data(), serializedData.size());
            client->send(buf, serializedData.size());
            serializedData.clear();
        }

        serializedData.insert(serializedData.end(), v.begin(), v.end());

    }

    if (!serializedData.empty()) {
        size_t size = serializedData.size();
        memcpy(buf, &size, sizeof(size_t));
        client->send(buf, sizeof(size_t));
        memcpy(buf, serializedData.data(), serializedData.size());
        client->send(buf, serializedData.size());
        serializedData.clear();
    }

    auto start = std::chrono::high_resolution_clock::now();
    for (int i = 0; i < 512; i++) {
        client->recv(buf, 4096);
    }
    auto end = std::chrono::high_resolution_clock::now();

    std::cout << 512 / std::chrono::duration<double>(end - start).count() << " Ops" << std::endl;

    // ack to end
    client->send(buf, 1);

    cse498::free_mr(mr);
    delete client;
    delete[] buf;
    return 0;
}

void usage(char *command) {
    using namespace std;
    cout << command << " [-f <config file>]" << std::endl;
}
