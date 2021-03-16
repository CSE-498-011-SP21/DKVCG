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

    for (auto &r : clientBatch) {
        std::vector<char> v = serialize(r);
        *(size_t *) buf = v.size();
        client->send(buf, sizeof(size_t));
        memcpy(buf, v.data(), v.size());
        client->send(buf, v.size());
    }

    for (int i = 0; i < 512; i++) {
        client->recv(buf, 4096);
    }

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
