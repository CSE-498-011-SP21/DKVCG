/**
 * @file
 */

#include <data_t.hh>
#include <Messages.hh>
#include <tbb/concurrent_queue.h>

#ifndef KVCG_COMMUNICATION_HH
#define KVCG_COMMUNICATION_HH

struct Communication {
    Communication() {}

    virtual ~Communication() {}

    virtual void send(Response &&r) = 0;

    virtual bool try_recv(Response &r) = 0;

};

struct LocalCommunication final : public Communication {

    explicit LocalCommunication(int s) : response(), size(s) {
        response.set_capacity(s);
    }

    LocalCommunication(const LocalCommunication &) = delete;

    virtual inline ~LocalCommunication() {}

    virtual inline void send(Response &&r) {
        r.shouldFree_ = false;
        response.push(r);
    }

    virtual inline bool try_recv(Response &r) {
        bool b = response.try_pop(r);
        if(b){
            r.shouldFree_ = true;
        }
        return b;
    }

    int size;
private:
    tbb::concurrent_bounded_queue<Response> response;
};

#endif //KVCG_RESULTSBUFFERS_HH
