// SPDX-License-Identifier: GPL-2.0-or-later
#pragma once
#include <cstdint>
#include <set>
#include <vector>
namespace AzaharMetal {
// Half-open physical ranges; widen arithmetic before adding guest addresses.
struct TransferRange {
    uint32_t address=0,bytes=0;
    bool Overlaps(uint32_t start,uint32_t size) const {
        return bytes && size && uint64_t(address)<uint64_t(start)+size && uint64_t(start)<uint64_t(address)+bytes;
    }
    bool CoveredBy(uint32_t start,uint32_t size) const {
        return size && start<=address && uint64_t(start)+size>=uint64_t(address)+bytes;
    }
    void AddPages(std::vector<uint32_t>& pages) const {
        if(!bytes || !address)return;
        for(uint64_t page=address&~uint32_t(4095);page<uint64_t(address)+bytes;page+=4096)
            pages.push_back(uint32_t(page));
    }
    void AddPages(std::set<uint32_t>& pages) const {
        if(!bytes || !address)return;
        for(uint64_t page=address&~uint32_t(4095);page<uint64_t(address)+bytes;page+=4096)
            pages.insert(uint32_t(page));
    }
};
}
