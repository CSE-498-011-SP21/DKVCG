//
// Created by depaulsmiller on 1/15/21.
//

#include <iostream>
#include <thread>
#include <unistd.h>
#include <atomic>
#include <kvcg.cuh>
#include <vector>
#include <zipf.hh>
#include <boost/property_tree/ptree.hpp>
#include <boost/property_tree/json_parser.hpp>
#include <set>

namespace pt = boost::property_tree;


using BatchWrapper = std::vector<RequestWrapper<unsigned long long, data_t *>>;

double zetaN = 0.1;
std::atomic_bool flag;

struct ZipfianWorkloadConfig {
    ZipfianWorkloadConfig() {
        theta = 0.99;
        range = 1000000000;
        n = 10000000;
        ops = 10000;
        keysize = 8;
        ratio = 95;
        flag = false;
    }

    ZipfianWorkloadConfig(std::string filename) {
        pt::ptree root;
        pt::read_json(filename, root);
        theta = root.get<double>("theta", 0.99);
        range = root.get<int>("range", 10000000);
        n = root.get<int>("n", 10000);
        ops = root.get<int>("ops", 100000);
        keysize = root.get<size_t>("keysize", 8);
        ratio = root.get<int>("ratio", 95);
        flag = false;
    }


    ~ZipfianWorkloadConfig() {}

    double theta;
    int range;
    int n;
    int ops;
    size_t keysize;
    int ratio;
};

ZipfianWorkloadConfig zipfianWorkloadConfig;

extern "C" int getBatchesToRun() {
    return zipfianWorkloadConfig.ops;
}

extern "C" void initWorkload() {
    flag = false;
    zetaN = cse498::rand::zeta(zipfianWorkloadConfig.theta, zipfianWorkloadConfig.range);
}

extern "C" void changeWorkload() {
    flag = true;
}

extern "C" void initWorkloadFile(std::string filename) {
    flag = false;
    zipfianWorkloadConfig = ZipfianWorkloadConfig(filename);
    zetaN = cse498::rand::zeta(zipfianWorkloadConfig.theta, zipfianWorkloadConfig.range);
}

unsigned long long genRand(unsigned *seed, int n, double zetaN, double theta, std::atomic_bool &flag) {
    unsigned long long u = cse498::rand::rand_zipf_r(seed, n, zetaN, theta);
    if (flag) u = n + 1 - u;
    return u;
}

std::vector<RequestWrapper<unsigned long long, data_t *>>
generateWorkloadZipfLargeKey(size_t keySize, int size, double theta, int n, double zetaN, unsigned *seed,
                             int ratioOfReads) {

    std::vector<RequestWrapper<unsigned long long, data_t *>> vec;

    for (int i = 0; i < size; i++) {
        if (rand_r(seed) % 100 < ratioOfReads) {
            vec.push_back({(unsigned long long) genRand(seed, n, zetaN, theta, flag), 0, nullptr,
                           REQUEST_GET});
        } else {
            if (rand_r(seed) % 100 < 50) {
                vec.push_back({(unsigned long long) genRand(seed, n, zetaN, theta, flag), 0,
                               new data_t(keySize),
                               REQUEST_INSERT});
            } else {
                vec.push_back(
                        {(unsigned long long) genRand(seed, n, zetaN, theta, flag), 0, nullptr,
                         REQUEST_REMOVE});
            }
        }

    }
    return vec;

}

extern "C" BatchWrapper generateWorkloadBatch(unsigned int *seed, unsigned batchsize) {
    return generateWorkloadZipfLargeKey(zipfianWorkloadConfig.keysize, batchsize, zipfianWorkloadConfig.theta,
                                        zipfianWorkloadConfig.range, zetaN, seed, zipfianWorkloadConfig.ratio);
}

extern "C" std::vector<BatchWrapper> getPopulationBatches(unsigned int *seed, unsigned batchsize) {

    std::set<unsigned long long> keys;

    if (zipfianWorkloadConfig.range < zipfianWorkloadConfig.n) {
        exit(1);
    }

    while (keys.size() < zipfianWorkloadConfig.n) {
        keys.insert((rand_r(seed) % zipfianWorkloadConfig.range) + 1);
    }

    std::vector<BatchWrapper> batches;
    auto iter = keys.begin();

    while (iter != keys.end()) {
        std::vector<RequestWrapper<unsigned long long, data_t *>> vec;
        for (int i = 0; i < batchsize && iter != keys.end(); i++) {
            vec.push_back({*iter, 0, new data_t(zipfianWorkloadConfig.keysize), REQUEST_INSERT});
            ++iter;
        }
        batches.push_back(vec);
    }

    return batches;
}
