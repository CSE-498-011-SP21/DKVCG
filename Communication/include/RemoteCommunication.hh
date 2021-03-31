//
// Created by depaulsmiller on 3/16/21.
//
#include "Communication.hh"
#include <networklayer/connection.hh>

#ifndef DKVCG_REMOTECOMMUNICATION_HH
#define DKVCG_REMOTECOMMUNICATION_HH

struct RemoteCommunication final : public Communication {

    explicit RemoteCommunication(cse498::Connection *c, cse498::unique_buf *b) : conn(c), buf(b) {
        assert(b->isRegistered());
    }

    RemoteCommunication(const LocalCommunication &) = delete;

    virtual ~RemoteCommunication() {}

    virtual inline void send(Response &&r) {
        size_t s = serialize2(buf->get(), 4096, r);
        conn->send(*buf, s);
    }

    virtual inline bool try_recv(Response &r) {
        conn->recv(*buf, buf->size());
        std::vector<char> v(4096);
        buf->cpyFrom(v.data(), 4096);
        r = deserialize<Response>(v);
        return true;
    }

    int size;
private:
    cse498::Connection *conn;
    cse498::unique_buf *buf;
};

#endif //DKVCG_REMOTECOMMUNICATION_HH
