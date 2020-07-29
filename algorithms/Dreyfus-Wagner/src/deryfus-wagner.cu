#include "common.h"
#include "dreyfus-wagner.h"
#include <chrono>
#include <iostream>
#include <stdint.h>
#include <vector>
// #include <curand.h>
// #include <curand_kernel.h>
// #include <cuda.h>

// #define gpuErrchk(ans) { gpuAssert((ans), __FILE__, __LINE__); }

// inline void gpuAssert(cudaError_t code, const char *file, int line, bool
// abort = true) {
//     if (code != cudaSuccess) {
//         fprintf(stderr, "GPUassert: %s %s %d\n", cudaGetErrorString(code),
//         file, line); if (abort) exit(code);
//     }
// }

static int hostTable[(int)1e8];
static const int INF = 1e9;
static const int BLOCK_SIZE = 1024;

static __global__ void dreyfusWagnerFirstStep(const int *distances,
                                              int *dynamicTable,
                                              const int nodes, const int mask) {
    int nodeIndex = blockDim.x * blockIdx.x + threadIdx.x, tmp;
    if (nodeIndex >= nodes)
        return;

    for (int subMask = (mask - 1) & mask; subMask;
         subMask = (subMask - 1) & mask) {
        tmp = dynamicTable[subMask * nodes + nodeIndex] +
              dynamicTable[(mask ^ subMask) * nodes + nodeIndex];
        dynamicTable[mask * nodes + nodeIndex] =
            tmp < dynamicTable[mask * nodes + nodeIndex]
                ? tmp
                : dynamicTable[mask * nodes + nodeIndex];
    }
}

static __global__ void dreyfusWagnerSecondStep(const int *distances,
                                               int *dynamicTable,
                                               const int nodes,
                                               const int mask) {
    int nodeIndex = blockDim.x * blockIdx.x + threadIdx.x, tmp;
    if (nodeIndex >= nodes)
        return;

    for (int node2 = 0; node2 < nodes; node2++) {
        tmp = dynamicTable[mask * nodes + node2] +
              distances[nodeIndex * nodes + node2];
        dynamicTable[mask * nodes + nodeIndex] =
            tmp < dynamicTable[mask * nodes + nodeIndex]
                ? tmp
                : dynamicTable[mask * nodes + nodeIndex];
    }
}

static int *
copyDistancesToDevice(const std::vector<std::vector<int>> &distances) {
    for (int i = 0; i < distances.size(); i++) {
        for (int j = 0; j < distances.size(); j++) {
            hostTable[i * distances.size() + j] = distances[i][j];
        }
    }

    int *cudaDistances;
    cudaMalloc(&cudaDistances,
               distances.size() * distances.size() * sizeof(int));

    cudaMemcpy(cudaDistances, hostTable,
               distances.size() * distances.size() * sizeof(int),
               cudaMemcpyHostToDevice);

    return cudaDistances;
}

static int *
copyDynamicTableToDevice(const std::vector<std::vector<int>> &distances,
                         const std::vector<int> &terminals,
                         const int &fullMask) {
    for (int i = 0; i < (fullMask + 1); i++) {
        for (int j = 0; j < distances.size(); j++) {
            hostTable[i * distances.size() + j] = INF;
        }
    }
    for (int i = 0; i < terminals.size() - 1; i++) {
        hostTable[(1 << i) * distances.size() + terminals[i]] = 0;
    }

    int *cudaDynamicTable;
    cudaMalloc(&cudaDynamicTable,
               (fullMask + 1) * distances.size() * sizeof(int));

    cudaMemcpy(cudaDynamicTable, hostTable,
               (fullMask + 1) * distances.size() * sizeof(int),
               cudaMemcpyHostToDevice);

    return cudaDynamicTable;
}

DreyfusWagnerStatistics dreyfusWagner(std::vector<std::vector<int>> &distances,
                                      const std::vector<int> &terminals) {
    DreyfusWagnerStatistics statistics = {0, 0, 0, 0, 0, 0};
    if (terminals.size() <= 1) {
        return statistics;
    }
    const int fullMask = (1 << (terminals.size() - 1)) - 1;
    int grid_size_nodes = distances.size() / BLOCK_SIZE + 1;

    auto beforeFloydWarshall = std::chrono::steady_clock::now();
    floydWarshall(distances);
    auto afterFloydWarshall = std::chrono::steady_clock::now();
    statistics.distancesDuration =
        std::chrono::duration_cast<std::chrono::milliseconds>(
            afterFloydWarshall - beforeFloydWarshall)
            .count();

    auto beforeCopy = std::chrono::steady_clock::now();
    int *cudaDistances = copyDistancesToDevice(distances);
    int *cudaDynamicTable =
        copyDynamicTableToDevice(distances, terminals, fullMask);
    auto afterCopy = std::chrono::steady_clock::now();
    statistics.copyDuration =
        std::chrono::duration_cast<std::chrono::milliseconds>(afterCopy -
                                                              beforeCopy)
            .count();
    std::chrono::nanoseconds firstPhase(0), secondPhase(0);
    for (int mask = 1; mask <= fullMask; mask++) {
        auto beforeFirstStep = std::chrono::steady_clock::now();
        dreyfusWagnerFirstStep<<<grid_size_nodes, BLOCK_SIZE>>>(
            cudaDistances, cudaDynamicTable, distances.size(), mask);
        auto afterFirstStep = std::chrono::steady_clock::now();
        dreyfusWagnerSecondStep<<<grid_size_nodes, BLOCK_SIZE>>>(
            cudaDistances, cudaDynamicTable, distances.size(), mask);
        auto afterSecondStep = std::chrono::steady_clock::now();
        firstPhase += std::chrono::duration_cast<std::chrono::nanoseconds>(
            afterFirstStep - beforeFirstStep);
        secondPhase += std::chrono::duration_cast<std::chrono::nanoseconds>(
            afterSecondStep - afterFirstStep);
    }
    auto end = std::chrono::steady_clock::now();
    statistics.firstPhaseDuration =
        std::chrono::duration_cast<std::chrono::microseconds>(firstPhase)
            .count();
    statistics.secondPhaseDuration =
        std::chrono::duration_cast<std::chrono::microseconds>(secondPhase)
            .count();
    statistics.everythingDuration =
        std::chrono::duration_cast<std::chrono::milliseconds>(
            end - beforeFloydWarshall)
            .count();
    cudaMemcpy(&statistics.result,
               cudaDynamicTable +
                   (fullMask * distances.size() + terminals.back()),
               1 * sizeof(int), cudaMemcpyDeviceToHost);

    cudaFree(cudaDistances);
    cudaFree(cudaDynamicTable);

    return statistics;
}