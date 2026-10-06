// SPDX-License-Identifier: GPL-3.0-or-later
// Native-only storage ABI. Actual addresses are written and consumed on the
// GPU; JavaScript sees only the browser's opaque resource objects. A logical
// renderer buffer can exceed the browser's per-shared-allocation size limit.
template<class T> struct OmwPaged {
    const unsigned long long* pages;
    T* direct;
    unsigned long long first;
    __device__ OmwPaged(const unsigned long long* table):pages(table),direct(nullptr),first(0) {}
    __device__ OmwPaged(T* pointer):pages(nullptr),direct(pointer),first(0) {}
    template<class U> __device__ OmwPaged(const OmwPaged<U>& other):pages(other.pages),direct(other.direct),first(other.first) {}
    __device__ T& operator[](unsigned long long index) const {
        index+=first;
        if(direct)return direct[index];
        unsigned long long bytes=index*sizeof(T);
        return *reinterpret_cast<T*>(pages[bytes>>26]+(bytes&67108863ull));
    }
    __device__ OmwPaged operator+(unsigned long long offset) const {
        OmwPaged result=*this;result.first+=offset;return result;
    }
};
