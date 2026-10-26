// Compare the patched decoder with the pinned upstream implementation.
#include "core/arm/dyncom/arm_dyncom_dec.h"
#include <array>
#include <cassert>
#include <chrono>
#include <cstdio>
#include <random>
#include <thread>
#include <vector>
ARMDecodeStatus ReferenceDecodeARMInstruction(u32 instruction, int* index);
static void Check(u32 word) {
    int actual = -999, expected = -999;
    const auto reference = ReferenceDecodeARMInstruction(word, &expected);
    assert(DecodeARMInstruction(word, &actual) == reference);
    assert(actual == expected);
    actual = -999;
    assert(DecodeARMInstruction(word, &actual) == reference); // Immediate cache hit.
    assert(actual == expected);
}
static void RandomStream(u32 seed, unsigned count) {
    std::mt19937 random(seed);
    for (unsigned i = 0; i < count; ++i) Check(random());
}
int main() {
    for (u32 word : {0u, 0xffffffffu, 0xf57ff01fu, 0xe1a00000u, 0xe12fff1eu}) Check(word);
    // Exercise every combination of the commonly used opcode and condition bits.
    for (u32 condition = 0; condition < 16; ++condition)
        for (u32 opcode = 0; opcode < 4096; ++opcode) {
            const u32 word = (condition << 28) | ((opcode >> 4) << 20) | ((opcode & 15) << 4);
            Check(word); Check(word | 0x000fff0fu);
        }
    RandomStream(0x44535456, 1000000); // Includes replacement/collision pressure.
    std::vector<std::thread> threads;
    for (u32 seed = 1; seed <= 4; ++seed)
        threads.emplace_back([seed] { RandomStream(seed, 100000); });
    for (auto& thread : threads) thread.join();
    std::array<u32, 256> words;
    std::mt19937 random(42);
    for (auto& word : words) word = random();
    auto measure = [&](auto decode) {
        int index = -999; u32 sum = 0;
        const auto start = std::chrono::steady_clock::now();
        for (unsigned repeat = 0; repeat < 8192; ++repeat)
            for (u32 word : words) { decode(word, &index); sum += u32(index); }
        return std::pair{std::chrono::duration<double>(std::chrono::steady_clock::now() - start).count(), sum};
    };
    std::vector<u32> stream(262144);for(auto& word:stream)word=random();
    auto measureMisses=[&](auto decode) {
        int index=-999;u32 sum=0;const auto start=std::chrono::steady_clock::now();
        for(u32 word:stream) {decode(word,&index);sum+=u32(index);}
        return std::pair{std::chrono::duration<double>(std::chrono::steady_clock::now()-start).count(),sum};
    };
    const auto oldMisses=measureMisses(ReferenceDecodeARMInstruction),newMisses=measureMisses(DecodeARMInstruction);
    assert(oldMisses.second==newMisses.second);
    printf("Streaming-word cache-miss microbenchmark: upstream %.3fs, cached/masked %.3fs (%.1fx); not a gameplay speed prediction.\n",oldMisses.first,newMisses.first,oldMisses.first/newMisses.first);
    const auto original = measure(ReferenceDecodeARMInstruction);
    const auto cached = measure(DecodeARMInstruction);
    assert(original.second == cached.second);
    printf("ARM decoder: opcode/condition matrix, 1.4M random words, collisions/repeats and four threads match upstream.\n");
    printf("Repeated-word microbenchmark: upstream %.3fs, cached %.3fs (%.1fx); not a gameplay speed prediction.\n", original.first, cached.first, original.first / cached.first);
}
