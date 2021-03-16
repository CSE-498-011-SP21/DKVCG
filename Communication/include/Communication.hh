/**
 * @file
 */

#include <data_t.hh>
#include <Messages.hh>
#include <tbb/concurrent_queue.h>

#ifndef KVCG_COMMUNICATION_HH
#define KVCG_COMMUNICATION_HH

struct LocalCommunication {

    explicit LocalCommunication(int s) : response(), size(s) {
        response.set_capacity(s);
    }

    LocalCommunication(const LocalCommunication &) = delete;

    ~LocalCommunication() {}

    inline void send(Response &&r) {
        response.push(r);
    }

    inline bool try_recv(Response &r) {
        return response.try_pop(r);
    }

    int size;
private:
    tbb::concurrent_bounded_queue<Response> response;
};

using Communication = LocalCommunication;

#endif //KVCG_RESULTSBUFFERS_HH
