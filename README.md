### Dynamic Arena Allocator implementation for C3 Programming Language

### Features:
-  Individual stack-like deallocation on demand
-  Snapshots — for making a bunch of temporary allocations and then reclaiming them
-  Memory reserving through `ensure_capacity`
-  Fully configurable: you can choose `min_region_size`, whether to zero out memory, `backing_allocator` for regions, and more

### Usage
- include src/arena.c3 from this repo to your project, change the module name if desired
