// SPDX-License-Identifier: GPL-2.0-or-later
#pragma once
#include <array>
#include <cstddef>
namespace Pica::Shader {
// The interpreter's hardware stacks have fixed power-of-two capacities. Keep
// boost::circular_buffer's overwrite-oldest behaviour on overflow, without three
// heap allocations for every interpreted vertex. No guest code is generated.
template<class T,std::size_t Capacity> class InterpreterStack {
    static_assert(Capacity && (Capacity&(Capacity-1))==0);
public:
    bool empty() const { return count==0; }
    std::size_t size() const { return count; }
    T& back() { return values[(first+count-1)&(Capacity-1)]; }
    const T& back() const { return values[(first+count-1)&(Capacity-1)]; }
    void pop_back() { --count; }
    void push_back(const T& value) {
        values[(first+count)&(Capacity-1)]=value;
        if(count==Capacity)first=(first+1)&(Capacity-1);else ++count;
    }
private:
    std::array<T,Capacity> values;
    std::size_t first=0,count=0;
};
}
