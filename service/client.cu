#include <unistd.h>
#include "helper.cuh"
#include <networklayer/connectionless.hh>
#include <RemoteCommunication.hh>
#include <cmath>

int LOG_LEVEL = TRACE;

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
    for (int i = 0; i < 512; i++) {
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

    auto client = new cse498::Connection("127.0.0.1", false, 8080);
    client->connect();

    cse498::unique_buf buf;
    uint64_t key = 1;
    client->register_mr(buf, FI_READ | FI_WRITE | FI_SEND | FI_RECV, key);

    std::vector<RequestWrapper<unsigned long long, data_t *>> clientBatch;
    for (int i = 0; i < 512; i++) {
        clientBatch.push_back({(unsigned long long) (i + 1), new data_t(32), REQUEST_INSERT});
    }

    sendBatchAndRecvResponse(client, clientBatch, buf);
    endConnection(client, buf);

    delete client;
    return 0;
}

void usage(char *command) {
    using namespace std;
    cout << command << " [-f <config file>]" << std::endl;
}
