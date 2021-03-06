
// Primitive operations that sea code uses.
// In future we'll just import these with the FFI.
#include <stdio.h>
#include "Runtime.h"


// ----------------------------------------------------------------------------
/// @brief The map for a single function's stack frame.  One of these is
///        compiled as constant data into the executable for each function.
///
/// Storage of metadata values is elided if the %metadata parameter to
/// @llvm.gcroot is null.
struct FrameMap {
  int32_t NumRoots;    //< Number of roots in stack frame.
  int32_t NumMeta;     //< Number of metadata entries.  May be < NumRoots.
  const void *Meta[0]; //< Metadata for each root.
};


/// @brief A link in the dynamic shadow stack.  One of these is embedded in
///        the stack frame of each function on the call stack.
struct StackEntry {
  struct StackEntry *Next;    //< Link to next stack entry (the caller's).
  const struct FrameMap *Map; //< Pointer to constant FrameMap.
  void *Roots[0];             //< Stack roots (in-place array).
};


/// @brief The head of the singly-linked list of StackEntries.  Functions push
///        and pop onto this in their prologue and epilogue.
///
/// Since there is only a global list, this technique is not threadsafe.
struct StackEntry *llvm_gc_root_chain;


/// @brief Calls Visitor(root, meta) for each GC root on the stack.
///        root and meta are exactly the values passed to
///        @llvm.gcroot.
///
/// Visitor could be a function to recursively mark live objects.  Or it
/// might copy them to another heap or generation.
///
/// @param Visitor A function to invoke for every GC root on the stack.
void visitGCRoots(void (*Visitor)(void **Root, const void *Meta)) {
  for (struct StackEntry *R = llvm_gc_root_chain; R; R = R->Next) {
    unsigned i = 0;

    // For roots [0, NumMeta), the metadata pointer is in the FrameMap.
    for (unsigned e = R->Map->NumMeta; i != e; ++i)
      Visitor(&R->Roots[i], R->Map->Meta[i]);

    // For roots [NumMeta, NumRoots), the metadata pointer is null.
    for (unsigned e = R->Map->NumRoots; i != e; ++i)
      Visitor(&R->Roots[i], NULL);
  }
}


void traceGCRoots (int _x) {
  for (struct StackEntry *R = llvm_gc_root_chain; R; R = R->Next) {
    unsigned i = 0;

    printf ("map %p\n", R->Map);

    // For roots [0, NumMeta), the metadata pointer is in the FrameMap.
    for (unsigned e = R->Map->NumMeta; i != e; ++i)
      printf ("root with meta %p\n", R->Roots[i]);

    // For roots [NumMeta, NumRoots), the metadata pointer is null.
    for (unsigned e = R->Map->NumRoots; i != e; ++i)
      printf ("root no   meta %p\n", R->Roots[i]);
  }
} 

void*   ddcLlvmRootGetStart (int _x)
{
        return llvm_gc_root_chain;
}

nat_t   ddcLlvmRootIsEnd (void* p)
{       
        return (p == 0);
}


// ----------------------------------------------------------------------------
// Abort the program due to an inexhaustive case match.
// 
// When desugaring guards, if the compiler cannot determine that
// the guards are exhaustive then a call to this function is
// inserted as a default case.
//
Obj*    primErrorDefault(string_t* source, uint32_t line)
{
        fprintf ( stderr
                , "\nDDC runtime error: inexhaustive case match.\n at: %s:%d\n"
                , source, line);
        exit(1);

        return 0;
}

// Show a pointer.
string_t* primShowAddr (void* ptr)
{       string_t*  str = malloc(32);
        snprintf(str, 32, "%p", ptr);
        return str;
}


// Show an integer.
// This leaks the space for the string, but nevermind until we get a GC.
string_t* primShowInt (int i)
{       string_t* str = malloc(32);
        snprintf(str, 32, "%d", i);
        return str;
}

// Show a natural number.
// This leaks the space for the string, but nevermind until we get a GC.
string_t* primShowNat (nat_t i)
{       string_t* str = malloc(32);
        snprintf(str, 32, "%u", (unsigned int)i);
        return str;
}

// Show a Word64.
string_t* primShowWord64 (uint64_t w)
{       string_t* str = malloc(11);
        snprintf(str, 10, "%#08llx", w);
        return str;
}

// Show a Word32.
string_t* primShowWord32 (uint32_t w)
{       string_t* str = malloc(7);
        snprintf(str, 6, "%#04x", w);
        return str;
}

// Show a Word16.
string_t* primShowWord16 (uint16_t w)
{       string_t* str = malloc(5);
        snprintf(str, 4, "%#02x", w);
        return str;
}

// Show a Word8.
string_t* primShowWord8 (uint8_t w)
{       string_t* str = malloc(4);
        snprintf(str, 3, "%#01x", w);
        return str;
}


// Print a C string to stdout.
void primPutString (string_t* str)
{       fputs(str, stdout);
        fflush(stdout);
}


// Print a C string to stderr.
// Use this when printing an error from the runtime system.
void primFailString(string_t* str)
{       fputs(str, stderr);
        fflush(stderr);
}

// Print a text literal to stdout.
void primPutTextLit (string_t* str)
{       fputs(str, stdout);
        fflush(stdout);
}

// Print a text vector to stdout.
void primPutVector (Obj* obj)
{       string_t* str 
                = (string_t*) (_payloadRaw(obj) + 4);
        fputs(str, stdout);
        fflush(stdout);
}
