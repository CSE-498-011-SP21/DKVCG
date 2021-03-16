//
// Created by depaulsmiller on 3/16/21.
//
#include "Communication.hh"
#include <networklayer/connectionless.hh>

#ifndef DKVCG_REMOTECOMMUNICATION_HH
#define DKVCG_REMOTECOMMUNICATION_HH

struct RemoteCommunication final : public Communication {

    explicit RemoteCommunication(cse498::ConnectionlessClient *c) : isClient(true) {
        client = c;
        buf = new char[4096];
        c->registerMR(buf, 4096, mr);
    }

    explicit RemoteCommunication(cse498::ConnectionlessServer *c, cse498::addr_t addr) : isClient(false) {
        server = c;
        remoteAddr = addr;
        buf = new char[4096];
        c->registerMR(buf, 4096, mr);
    }

    RemoteCommunication(const LocalCommunication &) = delete;

    virtual ~RemoteCommunication() {
        cse498::free_mr(mr);
        delete[] buf;
    }

    virtual inline void send(Response &&r) {
        auto v = serialize(r);
        if (isClient) {
            client->send(v.data(), v.size());
        } else {
            server->send(remoteAddr, v.data(), v.size());
        }
    }

    virtual inline bool try_recv(Response &r) {
        if (isClient) {
            client->recv(buf, 4096);
        } else {
            server->recv(remoteAddr, buf, 4096);
        }
        std::vector<char> v(buf, buf + 4096);
        r = deserialize<Response>(v);
        return true;
    }

    int size;
private:
    bool isClient;
    union {
        cse498::ConnectionlessServer *server;
        cse498::ConnectionlessClient *client;
    };
    cse498::addr_t remoteAddr;
    char *buf;
    cse498::mr_t mr;
};

#endif //DKVCG_REMOTECOMMUNICATION_HH
