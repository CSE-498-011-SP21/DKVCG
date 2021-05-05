// See https://github.com/CSE-498-011-SP21/GPUHashmaps_cse498/blob/main/MegaKV/include/MegaKV.cuh

#include <mutex>
#include <atomic>

#ifndef SECONDARY_INDEX_CUH
#define SECONDARY_INDEX_CUH

template<typename K, typename V>
struct SIBucket {

    SIBucket() : anyFree(true), availible(255), pairs(new std::pair<K, V>[255]){
        for(int i = 0; i < 255; i++){
            availible[i] = true;
        }
    }
    ~SIBucket(){
        delete[] pairs;
    }

    uint8_t allocate(){
        std::lock_guard<std::mutex> lg(mtx);
        for(int i = 0; i < 255; i++){
            if(availible[i]){
                availible[i] = false;
                if(i == 254)
                    anyFree = false;
                return i;
            }
        }
        return 255;
    } // returns 255 on error

    void free(uint8_t i){
        std::lock_guard<std::mutex> lg(mtx);
        anyFree = true;
        availible[i] = true;
        pairs[i] = {K(), V()}; // assuming shared_ptr or caller can delete
    }

    /// not necessarily safe, but it is fast
    inline void get(uint8_t i, std::pair<K, V>& p){
        p = pairs[i];
    }

    inline void set(uint8_t i, std::pair<K, V>& p){
        pairs[i] = p;
    }


    std::mutex mtx;
    std::atomic_bool anyFree;
    std::vector<bool> availible; // 255 locations are availible in the store this is a bitmap
    std::pair<K, V>* pairs;
};

template<typename K, typename V>
struct SecondaryIndex {

    /// give the size log 2 up to
    explicit SecondaryIndex(uint32_t sizeLog2 = 8) : nbits(sizeLog2), buckets(new SIBucket<K,V>[(1 << sizeLog2)]){

    }

    ~SecondaryIndex(){
        delete[] buckets;
    }

    SIBucket<K,V>* getBucket(uint64_t hash){
        return &(buckets[(uint32_t)(hash >> (32 - nbits))]);
    }

    SIBucket<K,V>* alloc(uint8_t& loc, uint32_t& hash){
        for(uint32_t i = 0; i < (1 << nbits); i++){
            if(buckets[i].anyFree){ // can only observe that it is free when it is not at worst
                auto res = buckets[i].allocate();
                if(res != 255){
                    loc = res;
                    hash = (i << (32 - nbits)) | (uint32_t)loc;
                    return &buckets[i];
                }
            }
        }
        std::cerr << "Allocations full" << std::endl;
        exit(255);
        return nullptr;
    }

    SIBucket<K,V>* buckets;
    const uint32_t nbits; // top number of bits to refer to a bucket
};

#endif